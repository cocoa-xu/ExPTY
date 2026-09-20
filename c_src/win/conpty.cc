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

#include <cstdint>
#include <iostream>
#include <memory>
#include <Shlwapi.h> // PathCombine, PathIsRelative
#include <sstream>
#include <string>
#include <vector>
#include <locale>
#include <codecvt>
#include <Windows.h>
#include <strsafe.h>
#include "path_util.h"

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

struct pty_baton {
  ErlNifPid process;

  HANDLE hIn{INVALID_HANDLE_VALUE};
  HANDLE hOut{INVALID_HANDLE_VALUE};
  HPCON hpc{nullptr};
  std::wstring inName, outName;
  HANDLE hRealIn{INVALID_HANDLE_VALUE};
  HANDLE hShell{nullptr};
  HANDLE hWait{nullptr};
  bool write_ready{false};
  bool closed{false};
  bool exited{false};
  ErlNifMutex *mutex{nullptr};
  ErlNifCond *write_pipe_cond{nullptr};
  ErlNifTid write_pipe_tid;
  ErlNifTid read_tid;
  bool write_pipe_running{false};
  bool read_running{false};

  static ErlNifResourceType *type;

  DWORD write(void * data, size_t len);
  void close();
  bool is_closed();
  void await_write_pipe();
};
ErlNifResourceType * pty_baton::type = NULL;

DWORD pty_baton::write(void * data, size_t len) {
  DWORD dwWritten = 0;

  enif_mutex_lock(this->mutex);
  if (this->write_ready && !WriteFile(this->hRealIn, data, len, &dwWritten, NULL)) {
    dwWritten = 0;
  }
  enif_mutex_unlock(this->mutex);

  return dwWritten;
}

void pty_baton::await_write_pipe() {
  enif_mutex_lock(this->mutex);
  while (!this->write_ready && !this->closed) {
    enif_cond_wait(this->write_pipe_cond, this->mutex);
  }
  enif_mutex_unlock(this->mutex);
}

bool pty_baton::is_closed() {
  enif_mutex_lock(this->mutex);
  bool value = this->closed;
  enif_mutex_unlock(this->mutex);
  return value;
}

void pty_baton::close() {
  enif_mutex_lock(this->mutex);
  if (this->closed) {
    enif_mutex_unlock(this->mutex);
    return;
  }
  this->closed = true;
  this->write_ready = false;
  HANDLE hRealIn = this->hRealIn;
  this->hRealIn = INVALID_HANDLE_VALUE;
  if (this->write_pipe_cond != nullptr) {
    enif_cond_broadcast(this->write_pipe_cond);
  }
  enif_mutex_unlock(this->mutex);

  if (hRealIn != INVALID_HANDLE_VALUE) {
    CloseHandle(hRealIn);
  }

  // ClosePseudoConsole drains through the pipes, so it has to come first.
  if (this->hpc != nullptr) {
    HMODULE hLibrary = (HMODULE)LoadLibraryExW(L"kernel32.dll", 0, 0);
    if (hLibrary != nullptr) {
      PFNCLOSEPSEUDOCONSOLE const pfnClosePseudoConsole = (PFNCLOSEPSEUDOCONSOLE)GetProcAddress(hLibrary, "ClosePseudoConsole");
      if (pfnClosePseudoConsole) {
        pfnClosePseudoConsole(this->hpc);
      }
      FreeLibrary(hLibrary);
    }
    this->hpc = nullptr;
  }

  if (this->hIn != INVALID_HANDLE_VALUE) {
    DisconnectNamedPipe(this->hIn);
    CloseHandle(this->hIn);
    this->hIn = INVALID_HANDLE_VALUE;
  }
  if (this->hOut != INVALID_HANDLE_VALUE) {
    DisconnectNamedPipe(this->hOut);
    CloseHandle(this->hOut);
    this->hOut = INVALID_HANDLE_VALUE;
  }
  ErlNifTid self = enif_thread_self();
  if (this->write_pipe_running && !enif_equal_tids(self, this->write_pipe_tid)) {
    this->write_pipe_running = false;
    enif_thread_join(this->write_pipe_tid, NULL);
  }
  if (this->read_running && !enif_equal_tids(self, this->read_tid)) {
    this->read_running = false;
    enif_thread_join(this->read_tid, NULL);
  }
}

static void pty_baton_dtor(ErlNifEnv *, void *data) {
  pty_baton *baton = static_cast<pty_baton*>(data);

  if (baton->mutex != nullptr) {
    baton->close();
    if (baton->write_pipe_cond != nullptr) {
      enif_cond_destroy(baton->write_pipe_cond);
      baton->write_pipe_cond = nullptr;
    }
    enif_mutex_destroy(baton->mutex);
    baton->mutex = nullptr;
  }
  if (baton->hShell != nullptr) {
    CloseHandle(baton->hShell);
    baton->hShell = nullptr;
  }
  baton->~pty_baton();
}

static void *create_write_pipe(void *data) {
  pty_baton *baton = static_cast<pty_baton*>(data);

  HANDLE hPipe = INVALID_HANDLE_VALUE;
  while (!baton->is_closed()) {
    hPipe = CreateFileW(
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
    Sleep(1);
  }

  enif_mutex_lock(baton->mutex);
  bool closed = baton->closed;
  if (!closed) {
    baton->hRealIn = hPipe;
    baton->write_ready = hPipe != INVALID_HANDLE_VALUE;
  }
  enif_cond_signal(baton->write_pipe_cond);
  enif_mutex_unlock(baton->mutex);

  if (closed && hPipe != INVALID_HANDLE_VALUE) {
    CloseHandle(hPipe);
  }

  enif_release_resource((void *)baton);
  return nullptr;
}

static void *read_data(void *data) {
  pty_baton *baton = static_cast<pty_baton*>(data);

  DWORD dwRead;
  char buffer[1024];

  HANDLE hPipe = INVALID_HANDLE_VALUE;
  while (!baton->is_closed()) {
    hPipe = CreateFileW(
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
    Sleep(1);
  }

  while (hPipe != INVALID_HANDLE_VALUE) {
    // TODO:Wait for the named pipe to become available
    // while (!WaitNamedPipeW(baton->outName.c_str(), 5000)) {
    //   // The pipe is not available yet
    // }

    // Data is available to read
    // Read data from the named pipe client instance
    dwRead = 0;
    if (!ReadFile(hPipe, buffer, sizeof(buffer), &dwRead, NULL)) {
      // The pseudoconsole closed its end, i.e. the spawned process is gone.
      break;
    }
    if (dwRead) {
      ERL_NIF_TERM dataread;
      unsigned char * ptr;

      ErlNifEnv * msg_env = enif_alloc_env();
      if ((ptr = enif_make_new_binary(msg_env, dwRead, &dataread)) != nullptr) {
        memcpy(ptr, buffer, dwRead);
        enif_send(NULL, &baton->process, msg_env, enif_make_tuple2(msg_env,
          nif::atom(msg_env, "data"),
          dataread
        ));
        enif_free_env(msg_env);
      }
    }
  }

  if (hPipe != INVALID_HANDLE_VALUE) {
    CloseHandle(hPipe);
  }

  enif_release_resource((void *)baton);
  return nullptr;
}

static char pty_mutex_name[] = "ExPTY.ConPTY";
static char pty_cond_name[] = "ExPTY.ConPTYWritePipeReady";
static char write_pipe_thread_name[] = "ExPTY.ConPTYWritePipe";
static char read_thread_name[] = "ExPTY.ConPTYReader";

static pty_baton *get_pty_baton(ErlNifEnv *env, ERL_NIF_TERM term) {
  pty_baton *baton = nullptr;
  if (!enif_get_resource(env, term, pty_baton::type, (void **)&baton)) {
    return nullptr;
  }
  return baton;
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

    void *resource = enif_alloc_resource(pty_baton::type, sizeof(pty_baton));
    if (resource == NULL) {
      return nif::error(env, "Cannot allocate memory for pty resource");
    }
    pty_baton *baton = new (resource) pty_baton();
    ERL_NIF_TERM pty = enif_make_resource(env, resource);
    enif_release_resource(resource);

    baton->mutex = enif_mutex_create(pty_mutex_name);
    if (baton->mutex == nullptr) {
      return nif::error(env, "Cannot create mutex for pty resource");
    }
    baton->write_pipe_cond = enif_cond_create(pty_cond_name);
    if (baton->write_pipe_cond == nullptr) {
      return nif::error(env, "Cannot create condition variable for pty resource");
    }
    enif_self(env, &baton->process);

    HRESULT hr = CreateNamedPipesAndPseudoConsole({(SHORT)cols, (SHORT)rows}, inheritCursor ? 1/*PSEUDOCONSOLE_INHERIT_CURSOR*/ : 0, &baton->hIn, &baton->hOut, &baton->hpc, baton->inName, baton->outName, pipeNameW);

    // Restore default handling of ctrl+c
    SetConsoleCtrlHandler(NULL, FALSE);

    if (!SUCCEEDED(hr)) {
      return nif::error(env, "Cannot launch conpty");
    }

    std::string coninPipeNameStr = std::wstring_convert<std::codecvt_utf8<wchar_t>>().to_bytes(baton->inName);
    std::string conoutPipeNameStr = std::wstring_convert<std::codecvt_utf8<wchar_t>>().to_bytes(baton->outName);

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
      pty,
      conin,
      conout
    );
  }
  return erl_ret;
}

static ERL_NIF_TERM expty_pty_connect(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  // _pty, _file, _args, _cwd, _env
  ERL_NIF_TERM erl_ret;

  std::string cmdline;
  std::string cwd;
  std::vector<std::string> env_strings;

  BOOL fSuccess = FALSE;

  pty_baton *handle = get_pty_baton(env, argv[0]);
  if (handle == nullptr) {
    return nif::error(env, "Invalid pty handle");
  }

  if (nif::get(env, argv[1], cmdline) &&
      nif::get(env, argv[2], cwd) &&
      nif::get_env(env, argv[3], env_strings)) {

    std::wstring cmdline_w(path_util::to_wstring(cmdline));
    std::wstring cwd_w(path_util::to_wstring(cwd));

    // Prepare command line
    std::unique_ptr<wchar_t[]> mutableCommandline = std::make_unique<wchar_t[]>(cmdline_w.length() + 1);
    HRESULT hr = StringCchCopyW(mutableCommandline.get(), cmdline_w.length() + 1, cmdline_w.c_str());

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

    enif_keep_resource((void *)handle);
    if (enif_thread_create(write_pipe_thread_name, &handle->write_pipe_tid, create_write_pipe, static_cast<void*>(handle), NULL) != 0) {
      enif_release_resource((void *)handle);
      handle->close();
      return nif::error(env, "Cannot start the pty write thread");
    }
    handle->write_pipe_running = true;
    ConnectNamedPipe(handle->hIn, nullptr);
    handle->await_write_pipe();

    enif_keep_resource((void *)handle);
    if (enif_thread_create(read_thread_name, &handle->read_tid, read_data, static_cast<void*>(handle), NULL) != 0) {
      enif_release_resource((void *)handle);
      handle->close();
      return nif::error(env, "Cannot start the pty read thread");
    }
    handle->read_running = true;
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
    std::unique_ptr<BYTE[]> attrList = std::make_unique<BYTE[]>(size);
    siEx.lpAttributeList = reinterpret_cast<PPROC_THREAD_ATTRIBUTE_LIST>(attrList.get());

    fSuccess = InitializeProcThreadAttributeList(siEx.lpAttributeList, 1, 0, &size);
    if (!fSuccess) {
      handle->close();
      return nif::error(env, "InitializeProcThreadAttributeList failed");
    }

    fSuccess = UpdateProcThreadAttribute(siEx.lpAttributeList,
                                        0,
                                        PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                                        handle->hpc,
                                        sizeof(HPCON),
                                        NULL,
                                        NULL);

    if (!fSuccess) {
      DeleteProcThreadAttributeList(siEx.lpAttributeList);
      handle->close();
      return nif::error(env, "UpdateProcThreadAttribute failed");
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
    DeleteProcThreadAttributeList(siEx.lpAttributeList);
    if (!fSuccess) {
      handle->close();
      return nif::error(env, "Cannot create process");
    }

    // Update handle
    handle->hShell = piClient.hProcess;
    CloseHandle(piClient.hThread);

    // Setup Windows wait for process exit event
    HANDLE hWait = nullptr;
    enif_keep_resource((void *)handle);
    if (!RegisterWaitForSingleObject(&hWait, piClient.hProcess, OnProcessExitWinEvent, (PVOID)handle, INFINITE, WT_EXECUTEONLYONCE)) {
      enif_release_resource((void *)handle);
      handle->close();
      return nif::error(env, "Cannot wait for the pty process to exit");
    }

    enif_mutex_lock(handle->mutex);
    bool exited = handle->exited;
    if (!exited) {
      handle->hWait = hWait;
    }
    enif_mutex_unlock(handle->mutex);
    if (exited) {
      UnregisterWaitEx(hWait, NULL);
    }
    
    // Return
    return enif_make_tuple2(env, nif::atom(env, "ok"), enif_make_int64(env, piClient.dwProcessId));
  } else {
    return enif_make_badarg(env);
  }
}

static ERL_NIF_TERM expty_write(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ERL_NIF_TERM erl_ret;

  pty_baton *handle = get_pty_baton(env, argv[0]);
  if (handle == nullptr) {
    return nif::error(env, "Invalid pty handle");
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
  return erl_ret;
}

static ERL_NIF_TERM expty_resize(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  int cols, rows;

  pty_baton *handle = get_pty_baton(env, argv[0]);
  if (handle == nullptr) {
    return nif::error(env, "invalid pty handle");
  }

  if (nif::get(env, argv[1], &cols) && cols > 0 &&
      nif::get(env, argv[2], &rows) && rows > 0) {
    HMODULE hLibrary = (HMODULE)LoadLibraryExW(L"kernel32.dll", 0, 0);
    if (hLibrary == nullptr) {
      return nif::error(env, "cannot load kernel32.dll");
    }

    PFNRESIZEPSEUDOCONSOLE const pfnResizePseudoConsole = (PFNRESIZEPSEUDOCONSOLE)GetProcAddress(hLibrary, "ResizePseudoConsole");
    if (!pfnResizePseudoConsole) {
      FreeLibrary(hLibrary);
      return nif::error(env, "cannot find function ResizePseudoConsole");
    }

    enif_mutex_lock(handle->mutex);
    bool closed = handle->closed;
    if (!closed) {
      COORD size = {(SHORT)cols, (SHORT)rows};
      pfnResizePseudoConsole(handle->hpc, size);
    }
    enif_mutex_unlock(handle->mutex);
    FreeLibrary(hLibrary);

    if (closed) {
      return nif::error(env, "pty is closed");
    }
    return nif::atom(env, "ok");
  } else {
    return enif_make_badarg(env);
  }
}

static ERL_NIF_TERM expty_close(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  pty_baton *handle = get_pty_baton(env, argv[0]);
  if (handle == nullptr) {
    return nif::error(env, "invalid pty handle");
  }

  handle->close();
  return nif::atom(env, "ok");
}

static ERL_NIF_TERM expty_stub(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  return nif::error(env, "invalid NIF call to platform-specific implementation");
}

VOID CALLBACK OnProcessExitWinEvent(
    _In_ PVOID context,
    _In_ BOOLEAN TimerOrWaitFired) {
  pty_baton *baton = static_cast<pty_baton*>(context);

  enif_mutex_lock(baton->mutex);
  baton->exited = true;
  HANDLE hWait = baton->hWait;
  baton->hWait = nullptr;
  enif_mutex_unlock(baton->mutex);

  // NULL as the completion event is required: we are running inside the wait
  // callback, so asking to wait for outstanding callbacks would deadlock.
  if (hWait != nullptr) {
    UnregisterWaitEx(hWait, NULL);
  }

  DWORD exitCode = 0;
  GetExitCodeProcess(baton->hShell, &exitCode);

  // Unix reports the terminating signal as the fourth argument of `on_exit`,
  // Windows has no equivalent and reports `nil`.
  ErlNifEnv * msg_env = enif_alloc_env();
  enif_send(NULL, &baton->process, msg_env, enif_make_tuple3(msg_env,
    nif::atom(msg_env, "exit"),
    enif_make_int(msg_env, exitCode),
    nif::atom(msg_env, "nil")
  ));
  enif_free_env(msg_env);

  baton->close();
  enif_release_resource((void *)baton);
}

/**
* Init
*/

static int on_load(ErlNifEnv * env, void **, ERL_NIF_TERM) {
  ErlNifResourceType *rt =
    enif_open_resource_type(env, "Elixir.ExPTY.Nif", "pty_baton", pty_baton_dtor, ERL_NIF_RT_CREATE, NULL);
  if (!rt) return -1;

  pty_baton::type = rt;
  return 0;
}

static int on_reload(ErlNifEnv *, void **, ERL_NIF_TERM) {
  return 0;
}

static int on_upgrade(ErlNifEnv *, void **, void **, ERL_NIF_TERM) {
  return 0;
}

static ErlNifFunc nif_functions[] = {
  {"spawn_win32", 6, expty_spawn, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"write", 2, expty_write, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"resize", 3, expty_resize, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"connect_win32", 4, expty_pty_connect, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"close", 1, expty_close, ERL_NIF_DIRTY_JOB_IO_BOUND},

  // stubs
  {"spawn_unix", 14, expty_stub, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"pause", 1, expty_stub, ERL_DIRTY_JOB_IO_BOUND},
  {"resume", 1, expty_stub, ERL_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(Elixir.ExPTY.Nif, nif_functions, on_load, on_reload, on_upgrade, NULL);
