/**
 * Copyright (c) 2019, Microsoft Corporation (MIT License).
 * Copyright (c) 2023, Cocoa Xu (Apache 2.0 License).
 */

#include <windows.h>
#include <stdio.h>
#include <vector>

int main(int argc, const char * argv[]) {
  if (argc != 2) {
    printf("Usage: conpty_console_list shellPid\r\n");
    return -1;
  }

  DWORD self_pid = GetCurrentProcessId();
  const SHORT pid = (SHORT)atoi(argv[1]);

  if (!FreeConsole()) {
    printf("FreeConsole failed\r\n");
    return -2;
  }
  if (!AttachConsole(pid)) {
    printf("AttachConsole failed\r\n");
    return -3;
  }
  auto processList = std::vector<DWORD>(64);
  auto processCount = GetConsoleProcessList(&processList[0], processList.size());
  if (processList.size() < processCount) {
      processList.resize(processCount);
      processCount = GetConsoleProcessList(&processList[0], processList.size());
  }
  FreeConsole();
  if (!AttachConsole(self_pid)) {
    printf("AttachConsole failed\r\n");
    return -4;
  }

  for (DWORD i = 0; i < processCount; i++) {
    printf("%d,", processList[i]);
  }
  printf("\r\n");
  return 0;
}
