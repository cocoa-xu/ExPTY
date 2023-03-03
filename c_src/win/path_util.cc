/**
 * Copyright (c) 2013-2015, Christopher Jeffrey, Peter Sunde (MIT License)
 * Copyright (c) 2016, Daniel Imms (MIT License).
 * Copyright (c) 2018, Microsoft Corporation (MIT License).
 * Copyright (c) 2023, Cocoa Xu (Apache 2.0 License).
 */

#include <Shlwapi.h> // PathCombine
#include <string>
#include <vector>
#include <winbase.h>
#include <wchar.h>

#include "path_util.h"

namespace path_util {

std::wstring to_wstring(const std::string& str) {
  const char * bytes = str.c_str();
  int slen = (int)str.length();
  int sizeOfStr = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes, slen, 0, 0);
  wchar_t *output = new wchar_t[sizeOfStr + 1];
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, bytes, slen, output, sizeOfStr);
  output[sizeOfStr] = L'\0';
  auto ret = std::wstring(output);
  delete[] output;
  return ret;
}

bool file_exists(std::wstring filename) {
  DWORD attr = ::GetFileAttributesW(filename.c_str());
  if (attr == INVALID_FILE_ATTRIBUTES || (attr & FILE_ATTRIBUTE_DIRECTORY)) {
    return false;
  }
  return true;
}

// cmd.exe -> C:\Windows\system32\cmd.exe
std::wstring get_shell_path(std::wstring filename) {
  std::wstring shellpath;

  if (file_exists(filename)) {
    return shellpath;
  }

  wchar_t buffer_[MAX_ENV];
  int read = ::GetEnvironmentVariableW(L"Path", buffer_, MAX_ENV);
  if (!read) {
    return shellpath;
  }

  std::wstring delimiter = L";";
  size_t pos = 0;
  std::vector<std::wstring> paths;
  std::wstring buffer(buffer_);
  while ((pos = buffer.find(delimiter)) != std::wstring::npos) {
    paths.push_back(buffer.substr(0, pos));
    buffer.erase(0, pos + delimiter.length());
  }

  const wchar_t *filename_ = filename.c_str();

  for (size_t i = 0; i < paths.size(); ++i) {
    std::wstring path = paths[i];
    wchar_t searchPath[MAX_PATH];
    ::PathCombineW(searchPath, const_cast<wchar_t*>(path.c_str()), filename_);

    if (searchPath == NULL) {
      continue;
    }

    if (file_exists(searchPath)) {
      shellpath = searchPath;
      break;
    }
  }

  return shellpath;
}

}  // namespace path_util
