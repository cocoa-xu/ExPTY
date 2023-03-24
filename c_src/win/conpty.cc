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

VOID CALLBACK OnProcessExitWinEvent(
    _In_ PVOID context,
    _In_ BOOLEAN TimerOrWaitFired);
static void OnProcessExit(uv_async_t *async);

struct pty_baton {
  ErlNifEnv *env;
  ErlNifPid * process;

  int id;
  HANDLE hIn;
  HANDLE hOut;
  HPCON hpc;
  std::wstring inName, outName;
  HANDLE hRealIn;
  bool write_ready{false};
  uv_mutex_t mutex;

  HANDLE hShell;
  HANDLE hWait;
  uv_async_t async;
  uv_thread_t tid;

  pty_baton(ErlNifEnv *_env, ErlNifPid *_process, int _id, HANDLE _hIn, HANDLE _hOut, HPCON _hpc, std::wstring _inName, std::wstring _outName) : 
  env(_env), process(_process), id(_id), hIn(_hIn), hOut(_hOut), hpc(_hpc), inName(_inName), outName(_outName) {};

  DWORD write(void * data, size_t len);
};

DWORD pty_baton::write(void * data, size_t len) {
  // Write data to the named pipe server instance
  DWORD dwWritten;
  if (!this->write_ready) return 0;

  uv_mutex_lock(&this->mutex);

  if (!WriteFile(this->hRealIn, data, len, &dwWritten, NULL)) {
    return 0;
  }

  uv_mutex_unlock(&this->mutex);

  return dwWritten;
}

static void create_write_pipe(void *data) {
  pty_baton *baton = static_cast<pty_baton*>(data);

  if (baton->write_ready) return;

  HANDLE hPipe;
  while (true) {
    hPipe  = CreateFileW(
      baton->inName.c_str(), // Pipe name
      GENERIC_WRITE,             // Write access
      0,                          // No sharing
      NULL,                       // Default security attributes
      OPEN_EXISTING,              // Opens the existing pipe instance
      0,                          // Default attributes
      NULL                        // No template file
    );

    if (hPipe != INVALID_HANDLE_VALUE)
    {
      break;
    }
  }

  baton->hRealIn = hPipe;
  baton->write_ready = true;
}

static void read_data(void *data) {
  pty_baton *baton = static_cast<pty_baton*>(data);

  DWORD dwRead;
  char buffer[1024];

  HANDLE hPipe;
  while (true) {
    hPipe  = CreateFileW(
      baton->outName.c_str(), // Pipe name
      GENERIC_READ,             // Write access
      0,                          // No sharing
      NULL,                       // Default security attributes
      OPEN_EXISTING,              // Opens the existing pipe instance
      0,                          // Default attributes
      NULL                        // No template file
    );

    if (hPipe != INVALID_HANDLE_VALUE)
    {
      break;
    }
  }

  while (true) {
    // TODO:Wait for the named pipe to become available
    // while (!WaitNamedPipeW(baton->outName.c_str(), 5000)) {
    //   // The pipe is not available yet
    // }

    // Data is available to read
    // Read data from the named pipe client instance
    dwRead = 0;
    ReadFile(hPipe, buffer, sizeof(buffer), &dwRead, NULL);
    if (dwRead) {
      ERL_NIF_TERM dataread;
      unsigned char * ptr;

      ErlNifEnv * msg_env = enif_alloc_env();
      if ((ptr = enif_make_new_binary(msg_env, dwRead, &dataread)) != nullptr) {
        memcpy(ptr, buffer, dwRead);
        enif_send(NULL, baton->process, msg_env, enif_make_tuple2(msg_env,
          nif::atom(msg_env, "data"),
          dataread
        ));
        enif_free_env(msg_env);
      }
    }
  }
}

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

// Returns a new server named pipe.  It has not yet been connected.
bool createDataServerPipe(bool write,
                          std::wstring kind,
                          HANDLE* hServer,
                          std::wstring &name,
                          const std::wstring &pipeName)
{
  *hServer = INVALID_HANDLE_VALUE;

  name = L"\\\\.\\pipe\\" + pipeName + L"-" + kind;

  DWORD winOpenMode;
  if (write) {
    winOpenMode = PIPE_ACCESS_INBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE;
  } else {
    winOpenMode = PIPE_ACCESS_OUTBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE;
  }

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

static ERL_NIF_TERM expty_spawn(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
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

    ptyHandles.insert(ptyHandles.end(), new pty_baton(env, process, ptyId, hIn, hOut, hpc, inName, outName));

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

static ERL_NIF_TERM expty_pty_connect(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  // _pty_id, _file, _args, _cwd, _env
  ERL_NIF_TERM erl_ret;

  int pty_id;
  std::string file;
  std::vector<std::string> args;
  std::string cwd;
  std::vector<std::string> env_strings;

  BOOL fSuccess = FALSE;

  if (nif::get(env, argv[0], &pty_id) &&
      nif::get(env, argv[1], file) &&
      nif::get_list(env, argv[2], args) &&
      nif::get(env, argv[3], cwd) &&
      nif::get_env(env, argv[4], env_strings)) {
    // Fetch pty handle from ID and start process
    pty_baton* handle = get_pty_baton(pty_id);
    if (!handle) {
      erl_ret = nif::error(env, "Invalid pty handle");
      return erl_ret;
    }

    // TODO: make full cmdline
    std::wstring cmdline(path_util::to_wstring(file));
    std::wstring cwd_w(path_util::to_wstring(cwd));

    // Prepare command line
    std::unique_ptr<wchar_t[]> mutableCommandline = std::make_unique<wchar_t[]>(cmdline.length() + 1);
    HRESULT hr = StringCchCopyW(mutableCommandline.get(), cmdline.length() + 1, cmdline.c_str());

    // Prepare cwd
    std::unique_ptr<wchar_t[]> mutableCwd = std::make_unique<wchar_t[]>(cwd_w.length() + 1);
    hr = StringCchCopyW(mutableCwd.get(), cwd_w.length() + 1, cwd_w.c_str());

    // Prepare environment
    std::wstring env_w;
    if (env_strings.size()) {
      std::wstringstream envBlock;
      for(uint32_t i = 0; i < env_strings.size(); i++) {
        std::wstring envValue(path_util::to_wstring(env_strings[i]));
        envBlock << envValue << L'\0';
      }
      envBlock << L'\0';
      env_w = envBlock.str();
    }
    auto envV = vectorFromString(env_w);
    LPWSTR envArg = envV.empty() ? nullptr : envV.data();

    uv_mutex_init(&handle->mutex);
    uv_thread_create(&handle->tid, create_write_pipe, static_cast<void*>(handle));
    ConnectNamedPipe(handle->hIn, nullptr);
    uv_thread_create(&handle->tid, read_data, static_cast<void*>(handle));
    ConnectNamedPipe(handle->hOut, nullptr);

    // Attach the pseudoconsole to the client application we're creating
    STARTUPINFOEXW siEx{0};
    siEx.StartupInfo.cb = sizeof(STARTUPINFOEXW);
    siEx.StartupInfo.dwFlags |= STARTF_USESTDHANDLES;
    siEx.StartupInfo.hStdError = nullptr;
    siEx.StartupInfo.hStdInput = nullptr;
    siEx.StartupInfo.hStdOutput = nullptr;

    SIZE_T size = 0;
    InitializeProcThreadAttributeList(NULL, 1, 0, &size);
    BYTE *attrList = new BYTE[size];
    siEx.lpAttributeList = reinterpret_cast<PPROC_THREAD_ATTRIBUTE_LIST>(attrList);

    fSuccess = InitializeProcThreadAttributeList(siEx.lpAttributeList, 1, 0, &size);
    if (!fSuccess) {
      erl_ret = nif::error(env, "InitializeProcThreadAttributeList failed");
    }
    fSuccess = UpdateProcThreadAttribute(siEx.lpAttributeList,
                                        0,
                                        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                        handle->hpc,
                                        sizeof(HPCON),
                                        NULL,
                                        NULL);

    if (!fSuccess) {
      erl_ret = nif::error(env, "UpdateProcThreadAttribute failed");
      return erl_ret;
    }

    PROCESS_INFORMATION piClient{};
    fSuccess = !!CreateProcessW(
        nullptr,
        mutableCommandline.get(),
        nullptr,                      // lpProcessAttributes
        nullptr,                      // lpThreadAttributes
        false,                        // bInheritHandles VERY IMPORTANT that this is false
        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, // dwCreationFlags
        envArg,                       // lpEnvironment
        mutableCwd.get(),             // lpCurrentDirectory
        &siEx.StartupInfo,            // lpStartupInfo
        &piClient                     // lpProcessInformation
    );
    if (!fSuccess) {
      erl_ret = nif::error(env, "Cannot create process");
      return erl_ret;
    }

    // Update handle
    handle->hShell = piClient.hProcess;
    handle->async.data = handle;

    // Setup OnProcessExit callback
    uv_async_init(uv_default_loop(), &handle->async, OnProcessExit);

    // Setup Windows wait for process exit event
    RegisterWaitForSingleObject(&handle->hWait, piClient.hProcess, OnProcessExitWinEvent, (PVOID)handle, INFINITE, WT_EXECUTEONLYONCE);
    
    // Return
    return enif_make_tuple2(env, nif::atom(env, "ok"), enif_make_int64(env, piClient.dwProcessId));
  } else {
    return enif_make_badarg(env);
  }
}

static ERL_NIF_TERM expty_write(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  int pty_id;
  ERL_NIF_TERM erl_ret;

  if (nif::get(env, argv[0], &pty_id)) {
    // Fetch pty handle from ID and start process
    pty_baton* handle = get_pty_baton(pty_id);
    if (!handle) {
      erl_ret = nif::error(env, "Invalid pty handle");
      return erl_ret;
    }
  
    ErlNifBinary erl_bin;
    DWORD nbytes = 0;
    if (enif_inspect_binary(env, argv[1], &erl_bin)) {
      nbytes = handle->write(erl_bin.data, erl_bin.size);
    } else if (enif_inspect_iolist_as_binary(env, argv[1], &erl_bin)) {
      nbytes = handle->write(erl_bin.data, erl_bin.size);
    } else {
      return nif::error(env, "ExPTY.write/2 expects the second argument to be binary or iovec(s)");
    }

    if (nbytes == erl_bin.size) {
      erl_ret = nif::atom(env, "ok");
    } else {
      erl_ret = enif_make_tuple2(env, nif::atom(env, "partial"), enif_make_int64(env, nbytes));
    }
  } else {
    erl_ret = nif::error(env, "Cannot get pipesocket resource");
  }
  return erl_ret;
}

static ERL_NIF_TERM expty_resize(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  int pty_id, cols, rows;

  if (nif::get(env, argv[0], &pty_id) &&
      nif::get(env, argv[1], &cols) && cols > 0 &&
      nif::get(env, argv[2], &rows) && rows > 0) {
    const pty_baton* handle = get_pty_baton(pty_id);

    if (handle != nullptr) {
      HANDLE hLibrary = LoadLibraryExW(L"kernel32.dll", 0, 0);
      bool fLoadedDll = hLibrary != nullptr;
      if (fLoadedDll) {
        PFNRESIZEPSEUDOCONSOLE const pfnResizePseudoConsole = (PFNRESIZEPSEUDOCONSOLE)GetProcAddress((HMODULE)hLibrary, "ResizePseudoConsole");
        if (pfnResizePseudoConsole) {
          COORD size = {cols, rows};
          pfnResizePseudoConsole(handle->hpc, size);
          return nif::atom(env, "ok");
        } else {
          return nif::error(env, "cannot find function ResizePseudoConsole");
        }
      } else {
        return nif::error(env, "cannot load kernel32.dll");
      }
    } else {
      return nif::error(env, "invalid pty handle");
    }
  } else {
    return enif_make_badarg(env);
  }
}

VOID CALLBACK OnProcessExitWinEvent(
    _In_ PVOID context,
    _In_ BOOLEAN TimerOrWaitFired) {
  pty_baton *baton = static_cast<pty_baton*>(context);

  // Fire OnProcessExit
  uv_async_send(&baton->async);
}

void OnProcessExit(uv_async_t *async) {
  pty_baton *baton = static_cast<pty_baton*>(async->data);

  UnregisterWait(baton->hWait);

  // Get exit code
  DWORD exitCode = 0;
  GetExitCodeProcess(baton->hShell, &exitCode);

  ErlNifEnv * msg_env = enif_alloc_env();
  enif_send(NULL, baton->process, msg_env, enif_make_tuple2(msg_env,
    nif::atom(msg_env, "exit"),
    enif_make_int(msg_env, exitCode)
  ));
  enif_free_env(msg_env);

  uv_mutex_destroy(&baton->mutex);
  enif_free(baton->process);
  baton->process = NULL;
}

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
  return 0;
}

static int on_reload(ErlNifEnv *, void **, ERL_NIF_TERM) {
  return 0;
}

static int on_upgrade(ErlNifEnv *, void **, void **, ERL_NIF_TERM) {
  return 0;
}

static ErlNifFunc nif_functions[] = {
  {"spawn", 6, expty_spawn, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"write", 2, expty_write, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"resize", 3, expty_resize, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"priv_connect", 5, expty_pty_connect, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(Elixir.ExPTY.Nif, nif_functions, on_load, on_reload, on_upgrade, NULL);
