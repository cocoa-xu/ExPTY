/**
 * Copyright (c) 2013-2015, Christopher Jeffrey, Peter Sunde (MIT License)
 * Copyright (c) 2016, Daniel Imms (MIT License).
 * Copyright (c) 2018, Microsoft Corporation (MIT License).
 * Copyright (c) 2023, Cocoa Xu (Apache 2.0 License).
 *
 * pty.cc:
 *   This file is responsible for starting processes
 *   with pseudo-terminal file descriptors.
 */

#define WIN32_LEAN_AND_MEAN

#include <iostream>
#include <Shlwapi.h> // PathCombine, PathIsRelative
#include <sstream>
#include <string>
#include <vector>
#include <locale>
#include <codecvt>
#include <Windows.h>
#include <strsafe.h>
#include "path_util.h"

#include <uv.h>

#include <erl_nif.h>
#include "nif_utils.h"

// Taken from the RS5 Windows SDK, but redefined here in case we're targeting <= 17134
#ifndef PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE
#define PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE \
  ProcThreadAttributeValue(22, FALSE, TRUE, FALSE)
#endif

typedef VOID* HPCON;
typedef HRESULT (__stdcall *PFNCREATEPSEUDOCONSOLE)(COORD c, HANDLE hIn, HANDLE hOut, DWORD dwFlags, HPCON* phpcon);
typedef HRESULT (__stdcall *PFNRESIZEPSEUDOCONSOLE)(HPCON hpc, COORD newSize);
typedef void (__stdcall *PFNCLOSEPSEUDOCONSOLE)(HPCON hpc);

struct pty_baton {
  ErlNifEnv *env;
  ErlNifPid * process;

  int id;
  HANDLE hIn;
  HANDLE hOut;
  HPCON hpc;

  HANDLE hShell;
  HANDLE hWait;
  uv_async_t async;
  uv_thread_t tid;

  pty_baton(ErlNifEnv *_env, ErlNifPid *_process, int _id, HANDLE _hIn, HANDLE _hOut, HPCON _hpc) : 
  env(_env), process(_process), id(_id), hIn(_hIn), hOut(_hOut), hpc(_hpc) {};
};

static std::vector<pty_baton*> ptyHandles;
static volatile LONG ptyCounter;

static pty_baton* get_pty_baton(int id) {
  for (size_t i = 0; i < ptyHandles.size(); ++i) {
    pty_baton* ptyHandle = ptyHandles[i];
    if (ptyHandle->id == id) {
      return ptyHandle;
    }
  }
  return nullptr;
}

template <typename T>
std::vector<T> vectorFromString(const std::basic_string<T> &str) {
    return std::vector<T>(str.begin(), str.end());
}

// void throwNanError(const Nan::FunctionCallbackInfo<v8::Value>* info, const char* text, const bool getLastError) {
//   std::stringstream errorText;
//   errorText << text;
//   if (getLastError) {
//     errorText << ", error code: " << GetLastError();
//   }
//   Nan::ThrowError(errorText.str().c_str());
//   (*info).GetReturnValue().SetUndefined();
// }

// Returns a new server named pipe.  It has not yet been connected.
bool createDataServerPipe(bool write,
                          std::wstring kind,
                          HANDLE* hServer,
                          std::wstring &name,
                          const std::wstring &pipeName)
{
  *hServer = INVALID_HANDLE_VALUE;

  name = L"\\\\.\\pipe\\" + pipeName + L"-" + kind;

  const DWORD winOpenMode =  PIPE_ACCESS_INBOUND | PIPE_ACCESS_OUTBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE/*  | FILE_FLAG_OVERLAPPED */;

  SECURITY_ATTRIBUTES sa = {};
  sa.nLength = sizeof(sa);

  *hServer = CreateNamedPipeW(
      name.c_str(),
      /*dwOpenMode=*/winOpenMode,
      /*dwPipeMode=*/PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
      /*nMaxInstances=*/1,
      /*nOutBufferSize=*/0,
      /*nInBufferSize=*/0,
      /*nDefaultTimeOut=*/30000,
      &sa);

  return *hServer != INVALID_HANDLE_VALUE;
}

HRESULT CreateNamedPipesAndPseudoConsole(COORD size,
                                         DWORD dwFlags,
                                         HANDLE *phInput,
                                         HANDLE *phOutput,
                                         HPCON* phPC,
                                         std::wstring& inName,
                                         std::wstring& outName,
                                         const std::wstring& pipeName)
{
  HANDLE hLibrary = LoadLibraryExW(L"kernel32.dll", 0, 0);
  bool fLoadedDll = hLibrary != nullptr;
  if (fLoadedDll)
  {
    PFNCREATEPSEUDOCONSOLE const pfnCreate = (PFNCREATEPSEUDOCONSOLE)GetProcAddress((HMODULE)hLibrary, "CreatePseudoConsole");
    if (pfnCreate)
    {
      if (phPC == NULL || phInput == NULL || phOutput == NULL)
      {
        return E_INVALIDARG;
      }

      bool success = createDataServerPipe(true, L"in", phInput, inName, pipeName);
      if (!success)
      {
        return HRESULT_FROM_WIN32(GetLastError());
      }
      success = createDataServerPipe(false, L"out", phOutput, outName, pipeName);
      if (!success)
      {
        return HRESULT_FROM_WIN32(GetLastError());
      }
      return pfnCreate(size, *phInput, *phOutput, dwFlags, phPC);
    }
    else
    {
      // Failed to find CreatePseudoConsole in kernel32. This is likely because
      //    the user is not running a build of Windows that supports that API.
      //    We should fall back to winpty in this case.
      return HRESULT_FROM_WIN32(GetLastError());
    }
  }

  // Failed to find  kernel32. This is realy unlikely - honestly no idea how
  //    this is even possible to hit. But if it does happen, fall back to winpty.
  return HRESULT_FROM_WIN32(GetLastError());
}

static ERL_NIF_TERM expty_start_process(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  // file, cols, rows, debug, pipeName, inheritCursor
  ERL_NIF_TERM erl_ret;

  std::string file;
  int cols, rows;
  bool debug;
  std::string pipeName;
  bool inheritCursor;

  if (nif::get(env, argv[0], file) &&
      nif::get(env, argv[1], &cols) && cols > 0 &&
      nif::get(env, argv[2], &rows) && rows > 0 &&
      nif::get(env, argv[3], &debug) &&
      nif::get(env, argv[4], pipeName) &&
      nif::get(env, argv[5], &inheritCursor)) {
    std::wstring fileW, pipeNameW;

    std::wstring inName, outName;
    BOOL fSuccess = FALSE;
    std::unique_ptr<wchar_t[]> mutableCommandline;
    PROCESS_INFORMATION _piClient{};

    fileW = path_util::to_wstring(file);
    pipeNameW = path_util::to_wstring(pipeName);

    // use environment 'Path' variable to determine location of
    // the relative path that we have recieved (e.g cmd.exe)
    std::wstring shellpath;
    if (::PathIsRelativeW(fileW.c_str())) {
      shellpath = path_util::get_shell_path(fileW.c_str());
    } else {
      shellpath = fileW;
    }

    std::string shellpath_ = std::wstring_convert<std::codecvt_utf8<wchar_t>>().to_bytes(shellpath);

    if (shellpath.empty() || !path_util::file_exists(shellpath)) {
      std::stringstream why;
      why << "File not found: " << shellpath_;
      return nif::error(env, why.str().c_str());
    }

    HANDLE hIn, hOut;
    HPCON hpc;
    HRESULT hr = CreateNamedPipesAndPseudoConsole({(SHORT)cols, (SHORT)rows}, inheritCursor ? 1/*PSEUDOCONSOLE_INHERIT_CURSOR*/ : 0, &hIn, &hOut, &hpc, inName, outName, pipeNameW);

    // Restore default handling of ctrl+c
    SetConsoleCtrlHandler(NULL, FALSE);

    if (!SUCCEEDED(hr)) {
      return nif::error(env, "Cannot launch conpty");
    }

    // We were able to instantiate a conpty
    const int ptyId = InterlockedIncrement(&ptyCounter);
    ErlNifPid* process = (ErlNifPid *)enif_alloc(sizeof(ErlNifPid));
    if (process == NULL) {
      return nif::error(env, "Cannot allocate memory for ErlNifPid");
    }
    process = enif_self(env, process);

    ptyHandles.insert(ptyHandles.end(), new pty_baton(env, process, ptyId, hIn, hOut, hpc));

    std::string coninPipeNameStr = std::wstring_convert<std::codecvt_utf8<wchar_t>>().to_bytes(inName);
    std::string conoutPipeNameStr = std::wstring_convert<std::codecvt_utf8<wchar_t>>().to_bytes(outName);

    bool success;
    ERL_NIF_TERM conin = nif::make_string(env, coninPipeNameStr.c_str(), success);
    if (!success) {
      return nif::error(env, "Cannot allocate memory for coninPipeName");
    }
    ERL_NIF_TERM conout = nif::make_string(env, conoutPipeNameStr.c_str(), success);
    if (!success) {
      return nif::error(env, "Cannot allocate memory for conoutPipeName");
    }

    erl_ret = enif_make_tuple3(env,
      enif_make_int(env, ptyId),
      conin,
      conout
    );
  }
  return erl_ret;
}

VOID CALLBACK OnProcessExitWinEvent(
    _In_ PVOID context,
    _In_ BOOLEAN TimerOrWaitFired) {
  pty_baton *baton = static_cast<pty_baton*>(context);

  // Fire OnProcessExit
  uv_async_send(&baton->async);
}

static void OnProcessExit(uv_async_t *async) {
  // Nan::HandleScope scope;
  pty_baton *baton = static_cast<pty_baton*>(async->data);

  UnregisterWait(baton->hWait);

  // Get exit code
  DWORD exitCode = 0;
  GetExitCodeProcess(baton->hShell, &exitCode);

  // // Call function
  // v8::Local<v8::Value> args[1] = {
  //   Nan::New<v8::Number>(exitCode)
  // };

  // Nan::AsyncResource asyncResource("node-pty.callback");
  // baton->cb.Call(1, args, &asyncResource);
  // // Clean up
  // baton->cb.Reset();
}

// static NAN_METHOD(PtyConnect) {
//   Nan::HandleScope scope;

//   // If we're working with conpty's we need to call ConnectNamedPipe here AFTER
//   //    the Socket has attempted to connect to the other end, then actually
//   //    spawn the process here.

//   std::stringstream errorText;
//   BOOL fSuccess = FALSE;

//   if (info.Length() != 5 ||
//       !info[0]->IsNumber() ||
//       !info[1]->IsString() ||
//       !info[2]->IsString() ||
//       !info[3]->IsArray() ||
//       !info[4]->IsFunction()) {
//     Nan::ThrowError("Usage: pty.connect(id, cmdline, cwd, env, exitCallback)");
//     return;
//   }

//   const int id = info[0]->Int32Value(Nan::GetCurrentContext()).FromJust();
//   const std::wstring cmdline(path_util::to_wstring(Nan::Utf8String(info[1])));
//   const std::wstring cwd(path_util::to_wstring(Nan::Utf8String(info[2])));
//   const v8::Local<v8::Array> envValues = info[3].As<v8::Array>();
//   const v8::Local<v8::Function> exitCallback = v8::Local<v8::Function>::Cast(info[4]);

//   // Fetch pty handle from ID and start process
//   pty_baton* handle = get_pty_baton(id);
//   if (!handle) {
//     Nan::ThrowError("Invalid pty handle");
//     return;
//   }

//   // Prepare command line
//   std::unique_ptr<wchar_t[]> mutableCommandline = std::make_unique<wchar_t[]>(cmdline.length() + 1);
//   HRESULT hr = StringCchCopyW(mutableCommandline.get(), cmdline.length() + 1, cmdline.c_str());

//   // Prepare cwd
//   std::unique_ptr<wchar_t[]> mutableCwd = std::make_unique<wchar_t[]>(cwd.length() + 1);
//   hr = StringCchCopyW(mutableCwd.get(), cwd.length() + 1, cwd.c_str());

//   // Prepare environment
//   std::wstring env;
//   if (!envValues.IsEmpty()) {
//     std::wstringstream envBlock;
//     for(uint32_t i = 0; i < envValues->Length(); i++) {
//       std::wstring envValue(path_util::to_wstring(Nan::Utf8String(Nan::Get(envValues, i).ToLocalChecked())));
//       envBlock << envValue << L'\0';
//     }
//     envBlock << L'\0';
//     env = envBlock.str();
//   }
//   auto envV = vectorFromString(env);
//   LPWSTR envArg = envV.empty() ? nullptr : envV.data();

//   ConnectNamedPipe(handle->hIn, nullptr);
//   ConnectNamedPipe(handle->hOut, nullptr);

//   // Attach the pseudoconsole to the client application we're creating
//   STARTUPINFOEXW siEx{0};
//   siEx.StartupInfo.cb = sizeof(STARTUPINFOEXW);
//   siEx.StartupInfo.dwFlags |= STARTF_USESTDHANDLES;
//   siEx.StartupInfo.hStdError = nullptr;
//   siEx.StartupInfo.hStdInput = nullptr;
//   siEx.StartupInfo.hStdOutput = nullptr;

//   SIZE_T size = 0;
//   InitializeProcThreadAttributeList(NULL, 1, 0, &size);
//   BYTE *attrList = new BYTE[size];
//   siEx.lpAttributeList = reinterpret_cast<PPROC_THREAD_ATTRIBUTE_LIST>(attrList);

//   fSuccess = InitializeProcThreadAttributeList(siEx.lpAttributeList, 1, 0, &size);
//   if (!fSuccess) {
//     return throwNanError(&info, "InitializeProcThreadAttributeList failed", true);
//   }
//   fSuccess = UpdateProcThreadAttribute(siEx.lpAttributeList,
//                                        0,
//                                        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
//                                        handle->hpc,
//                                        sizeof(HPCON),
//                                        NULL,
//                                        NULL);
//   if (!fSuccess) {
//     return throwNanError(&info, "UpdateProcThreadAttribute failed", true);
//   }

//   PROCESS_INFORMATION piClient{};
//   fSuccess = !!CreateProcessW(
//       nullptr,
//       mutableCommandline.get(),
//       nullptr,                      // lpProcessAttributes
//       nullptr,                      // lpThreadAttributes
//       false,                        // bInheritHandles VERY IMPORTANT that this is false
//       EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, // dwCreationFlags
//       envArg,                       // lpEnvironment
//       mutableCwd.get(),             // lpCurrentDirectory
//       &siEx.StartupInfo,            // lpStartupInfo
//       &piClient                     // lpProcessInformation
//   );
//   if (!fSuccess) {
//     return throwNanError(&info, "Cannot create process", true);
//   }

//   // Update handle
//   handle->hShell = piClient.hProcess;
//   handle->cb.Reset(exitCallback);
//   handle->async.data = handle;

//   // Setup OnProcessExit callback
//   uv_async_init(uv_default_loop(), &handle->async, OnProcessExit);

//   // Setup Windows wait for process exit event
//   RegisterWaitForSingleObject(&handle->hWait, piClient.hProcess, OnProcessExitWinEvent, (PVOID)handle, INFINITE, WT_EXECUTEONLYONCE);

//   // Return
//   v8::Local<v8::Object> marshal = Nan::New<v8::Object>();
//   Nan::Set(marshal, Nan::New<v8::String>("pid").ToLocalChecked(), Nan::New<v8::Number>(piClient.dwProcessId));
//   info.GetReturnValue().Set(marshal);
// }

// static NAN_METHOD(PtyResize) {
//   Nan::HandleScope scope;

//   if (info.Length() != 3 ||
//       !info[0]->IsNumber() ||
//       !info[1]->IsNumber() ||
//       !info[2]->IsNumber()) {
//     Nan::ThrowError("Usage: pty.resize(id, cols, rows)");
//     return;
//   }

//   int id = info[0]->Int32Value(Nan::GetCurrentContext()).FromJust();
//   SHORT cols = info[1]->Uint32Value(Nan::GetCurrentContext()).FromJust();
//   SHORT rows = info[2]->Uint32Value(Nan::GetCurrentContext()).FromJust();

//   const pty_baton* handle = get_pty_baton(id);

//   if (handle != nullptr) {
//     HANDLE hLibrary = LoadLibraryExW(L"kernel32.dll", 0, 0);
//     bool fLoadedDll = hLibrary != nullptr;
//     if (fLoadedDll)
//     {
//       PFNRESIZEPSEUDOCONSOLE const pfnResizePseudoConsole = (PFNRESIZEPSEUDOCONSOLE)GetProcAddress((HMODULE)hLibrary, "ResizePseudoConsole");
//       if (pfnResizePseudoConsole)
//       {
//         COORD size = {cols, rows};
//         pfnResizePseudoConsole(handle->hpc, size);
//       }
//     }
//   }

//   return info.GetReturnValue().SetUndefined();
// }

// static NAN_METHOD(PtyKill) {
//   Nan::HandleScope scope;

//   if (info.Length() != 1 ||
//       !info[0]->IsNumber()) {
//     Nan::ThrowError("Usage: pty.kill(id)");
//     return;
//   }

//   int id = info[0]->Int32Value(Nan::GetCurrentContext()).FromJust();

//   const pty_baton* handle = get_pty_baton(id);

//   if (handle != nullptr) {
//     HANDLE hLibrary = LoadLibraryExW(L"kernel32.dll", 0, 0);
//     bool fLoadedDll = hLibrary != nullptr;
//     if (fLoadedDll)
//     {
//       PFNCLOSEPSEUDOCONSOLE const pfnClosePseudoConsole = (PFNCLOSEPSEUDOCONSOLE)GetProcAddress((HMODULE)hLibrary, "ClosePseudoConsole");
//       if (pfnClosePseudoConsole)
//       {
//         pfnClosePseudoConsole(handle->hpc);
//       }
//     }

//     DisconnectNamedPipe(handle->hIn);
//     DisconnectNamedPipe(handle->hOut);
//     CloseHandle(handle->hIn);
//     CloseHandle(handle->hOut);
//     CloseHandle(handle->hShell);
//   }

//   return info.GetReturnValue().SetUndefined();
// }

/**
* Init
*/

static int on_load(ErlNifEnv * env, void **, ERL_NIF_TERM) {
  // ErlNifResourceType *rt;
  // rt = enif_open_resource_type(env, "Elixir.ExPTY.Nif", "pty_pipesocket", NULL, ERL_NIF_RT_CREATE, NULL);
  // if (!rt) return -1;
  // pty_pipesocket::type = rt;
  return 0;
}

static int on_reload(ErlNifEnv *, void **, ERL_NIF_TERM) {
  return 0;
}

static int on_upgrade(ErlNifEnv *, void **, void **, ERL_NIF_TERM) {
  return 0;
}

static ErlNifFunc nif_functions[] = {
  {"start_process", 6, expty_start_process, ERL_NIF_DIRTY_JOB_IO_BOUND}
};

ERL_NIF_INIT(Elixir.ExPTY.Nif, nif_functions, on_load, on_reload, on_upgrade, NULL);
