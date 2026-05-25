#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <string>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <termios.h>
#include <unistd.h>
#include <string.h>

#include "common.h"

void bail (int type, int code) {
  int buf[2] = { type, code };
  (void)! write(COMM_PIPE_FD, &buf, sizeof(buf));
  _exit(1);
}

int main (int argc, char** argv) {
  sigset_t empty_set;
  sigemptyset(&empty_set);
  pthread_sigmask(SIG_SETMASK, &empty_set, nullptr);

  if (setsid() == -1) {
    bail(COMM_ERR_SETSID, errno);
  }

#if defined(TIOCSCTTY)
  if (ioctl(STDIN_FILENO, TIOCSCTTY, NULL) == -1) {
    bail(COMM_ERR_TIOCSCTTY, errno);
  }
#else
  char *slave_path = ttyname(STDIN_FILENO);
  if (slave_path == nullptr) {
    bail(COMM_ERR_TIOCSCTTY, errno);
  }
  int slave = open(slave_path, O_RDWR);
  if (slave == -1) {
    bail(COMM_ERR_TIOCSCTTY, errno);
  }
  close(slave);
#endif

  char *cwd = argv[1];
  int uid = std::stoi(argv[2]);
  int gid = std::stoi(argv[3]);
  bool closeFDs = std::stoi(argv[4]);
  char *file = argv[5];
  argv = &argv[5];

  fcntl(COMM_PIPE_FD, F_SETFD, FD_CLOEXEC);

  if (strlen(cwd) && chdir(cwd) == -1) {
    bail(COMM_ERR_CHDIR, errno);
  }
  if (gid != -1 && setgid(gid) == -1) {
    bail(COMM_ERR_SETGID, errno);
  }
  if (uid != -1 && setuid(uid) == -1) {
    bail(COMM_ERR_SETUID, errno);
  }
  if (closeFDs) {
    struct rlimit rlim_ofile;
    getrlimit(RLIMIT_NOFILE, &rlim_ofile);
    for (rlim_t fd = STDERR_FILENO + 1; fd < rlim_ofile.rlim_cur; fd++) {
      if (fd != COMM_PIPE_FD) {
        close(fd);
      }
    }
  }

  execvp(file, argv);
  bail(COMM_ERR_EXEC, errno);
  return 1;
}
