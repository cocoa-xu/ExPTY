#include <sys/types.h>
#include "common.h"
#include <vector>
#include <string>

#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

// #include <sys/types.h>
#include <sys/stat.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>

#include <uv.h>

#include <erl_nif.h>
#include "nif_utils.h"

/* forkpty */
/* http://www.gnu.org/software/gnulib/manual/html_node/forkpty.html */
#if defined(__GLIBC__) || defined(__CYGWIN__)
#include <pty.h>
#elif defined(__APPLE__) || defined(__OpenBSD__) || defined(__NetBSD__)
#include <util.h>
#elif defined(__FreeBSD__)
#include <libutil.h>
#elif defined(__sun)
#include <stropts.h> /* for I_PUSH */
#else
#include <pty.h>
#endif

#include <termios.h> /* tcgetattr, tty_ioctl */

/* Some platforms name VWERASE and VDISCARD differently */
#if !defined(VWERASE) && defined(VWERSE)
#define VWERASE	VWERSE
#endif
#if !defined(VDISCARD) && defined(VDISCRD)
#define VDISCARD	VDISCRD
#endif

/* for pty_getproc */
#if defined(__linux__)
#include <stdio.h>
#include <stdint.h>
#elif defined(__APPLE__)
#include <sys/sysctl.h>
#include <libproc.h>
#endif

/* NSIG - macro for highest signal + 1, should be defined */
#ifndef NSIG
#define NSIG 32
#endif

#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
  #define HAVE_POSIX_SPAWN_CLOEXEC_DEFAULT 1
#else
  #define HAVE_POSIX_SPAWN_CLOEXEC_DEFAULT 0
  #define POSIX_SPAWN_CLOEXEC_DEFAULT 0
#endif

#ifndef POSIX_SPAWN_USEVFORK
  #define POSIX_SPAWN_USEVFORK 0
#endif

/**
 * Structs
 */

struct pty_baton {
  ErlNifEnv *env;
  ErlNifPid * process;
  int exit_code;
  int signal_code;
  pid_t pid;
  uv_async_t async;
  uv_thread_t tid;
};

typedef struct pty_pipesocket_ {
  int fd;
  
  ErlNifEnv *env;
  ErlNifPid * process;
  
  uv_async_t async;
  uv_thread_t tid;
  uv_mutex_t mutex;
  uv_pipe_t handle_;
  
  static ErlNifResourceType * type;
  size_t write(void * data, size_t len);
} pty_pipesocket;
ErlNifResourceType * pty_pipesocket::type = NULL;

typedef struct nif_globals_ {
  ErlNifResourceType *fn;
  ErlNifResourceType *hostfxr_resource;
  ErlNifResourceType *bridge_resource;
  ErlNifResourceType *callback_resource;
  ErlNifResourceType *pointer_resource;
  ErlNifPid owner;
} nif_globals;

typedef struct callback_resource_ {
  ErlNifCond* condition;
  ErlNifEnv* env;
  ERL_NIF_TERM result;
} callback_resource;

static int pty_nonblock(int fd);
static int pty_openpty(int *, int *, char *,
  const struct termios *,
  const struct winsize *);
static void pty_waitpid(void *);
static void pty_after_waitpid(uv_async_t *);
static void pty_after_close(uv_handle_t *);

static void pty_pipesocket_fn(void *data);
static void pty_after_pipesocket(uv_async_t *);
static void pty_after_close_pipesocket(uv_handle_t *);

static ERL_NIF_TERM throw_for_errno(ErlNifEnv *env, const char* message, int _errno);

static ERL_NIF_TERM expty_spawn(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  // file, args, env, cwd, cols, rows, uid, gid, is_utf8, closeFDs, helper_path
  ERL_NIF_TERM erl_ret = nif::error(env, "error");
  std::string file;
  std::vector<std::string> args;
  std::vector<std::string> envs;
  std::string cwd;
  int cols, rows;
  int uid, gid;
  bool is_utf8, closeFDs;
  std::string helper_path;
  if (nif::get(env, argv[0], file) && 
      nif::get_list(env, argv[1], args) &&
      nif::get_env(env, argv[2], envs) &&
      nif::get(env, argv[3], cwd) &&
      nif::get(env, argv[4], &cols) && cols > 0 &&
      nif::get(env, argv[5], &rows) && rows > 0 &&
      nif::get(env, argv[6], &uid) &&
      nif::get(env, argv[7], &gid) &&
      nif::get(env, argv[8], &is_utf8) &&
      nif::get(env, argv[9], &closeFDs) &&
      nif::get(env, argv[10], helper_path)) {

    // debug
    // printf("file=%s\r\n", file.c_str());
    // for (size_t index = 0; index < args.size(); index++) {
    //   printf("args[%lu]=%s\r\n", index, args[index].c_str());
    // }
    // for (size_t index = 0; index < envs.size(); index++) {
    //   printf("env[%lu]: %s\r\n", index, envs[index].c_str());
    // }
    // printf("cwd=%s\r\n", cwd.c_str());
    // printf("cols=%d, rows=%d\r\n", cols, rows);
    // printf("uid=%d, gid=%d\r\n", uid, gid);
    // printf("helperPath=%s\r\n", helper_path.c_str());

    int envc = (int)envs.size();
    char **envs_c = new char*[envc+1];
    envs_c[envc] = NULL;
    for (int i = 0; i < envc; i++) {
      envs_c[i] = strdup(envs[i].c_str());
    }

    // size
    struct winsize winp;
    winp.ws_col = cols;
    winp.ws_row = rows;
    winp.ws_xpixel = 0;
    winp.ws_ypixel = 0;

    struct termios t = termios();
    struct termios *term = &t;
    term->c_iflag = ICRNL | IXON | IXANY | IMAXBEL | BRKINT;
    if (is_utf8) {
#if defined(IUTF8)
      term->c_iflag |= IUTF8;
#endif
    }
    term->c_oflag = OPOST | ONLCR;
    term->c_cflag = CREAD | CS8 | HUPCL;
    term->c_lflag = ICANON | ISIG | IEXTEN | ECHO | ECHOE | ECHOK | ECHOKE | ECHOCTL;

    term->c_cc[VEOF] = 4;
    term->c_cc[VEOL] = -1;
    term->c_cc[VEOL2] = -1;
    term->c_cc[VERASE] = 0x7f;
    term->c_cc[VWERASE] = 23;
    term->c_cc[VKILL] = 21;
    term->c_cc[VREPRINT] = 18;
    term->c_cc[VINTR] = 3;
    term->c_cc[VQUIT] = 0x1c;
    term->c_cc[VSUSP] = 26;
    term->c_cc[VSTART] = 17;
    term->c_cc[VSTOP] = 19;
    term->c_cc[VLNEXT] = 22;
    term->c_cc[VDISCARD] = 15;
    term->c_cc[VMIN] = 1;
    term->c_cc[VTIME] = 0;

#if (__APPLE__)
    term->c_cc[VDSUSP] = 25;
    term->c_cc[VSTATUS] = 20;
#endif

    // closeFDs
    bool explicitlyCloseFDs = closeFDs && !HAVE_POSIX_SPAWN_CLOEXEC_DEFAULT;

    const int EXTRA_ARGS = 6;
    int argc = (int)args.size();
    int argl = argc + EXTRA_ARGS + 1;
    char **argv = new char*[argl];
    argv[0] = strdup(helper_path.c_str());
    argv[1] = strdup(cwd.c_str());
    argv[2] = strdup(std::to_string(uid).c_str());
    argv[3] = strdup(std::to_string(gid).c_str());
    argv[4] = strdup(explicitlyCloseFDs ? "1": "0");
    argv[5] = strdup(file.c_str());
    argv[argl - 1] = NULL;
    for (int i = 0; i < argc; i++) {
      argv[i + EXTRA_ARGS] = strdup(args[i].c_str());
    }

    cfsetispeed(term, B38400);
    cfsetospeed(term, B38400);

    sigset_t newmask, oldmask;
    int flags = POSIX_SPAWN_USEVFORK;

    // temporarily block all signals
    // this is needed due to a race condition in openpty
    // and to avoid running signal handlers in the child
    // before exec* happened
    sigfillset(&newmask);
    pthread_sigmask(SIG_SETMASK, &newmask, &oldmask);

    int master, slave;
    int ret = pty_openpty(&master, &slave, nullptr, term, &winp);
    if (ret == -1) {
      erl_ret = nif::error(env, "openpty() failed.");
      goto done;
    }

    int comms_pipe[2];
    if (pipe(comms_pipe)) {
      erl_ret = nif::error(env, "pipe() failed.");
      goto done;
    }

    posix_spawn_file_actions_t acts;
    posix_spawn_file_actions_init(&acts);
    posix_spawn_file_actions_adddup2(&acts, slave, STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&acts, slave, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&acts, slave, STDERR_FILENO);
    posix_spawn_file_actions_adddup2(&acts, comms_pipe[1], COMM_PIPE_FD);
    posix_spawn_file_actions_addclose(&acts, comms_pipe[1]);

    posix_spawnattr_t attrs;
    posix_spawnattr_init(&attrs);
    if (closeFDs) {
      flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
    }
    posix_spawnattr_setflags(&attrs, flags);

    { // suppresses "jump bypasses variable initialization" errors
      pid_t pid;
      auto error = posix_spawn(&pid, argv[0], &acts, &attrs, argv, envs_c);

      close(comms_pipe[1]);

      // reenable signals
      pthread_sigmask(SIG_SETMASK, &oldmask, NULL);

      if (error) {
        erl_ret = throw_for_errno(env, "posix_spawn failed: ", error);
        goto done;
      }

      int helper_error[2];
      auto bytes_read = read(comms_pipe[0], &helper_error, sizeof(helper_error));
      close(comms_pipe[0]);

      if (bytes_read == sizeof(helper_error)) {
        if (helper_error[0] == COMM_ERR_EXEC) {
          erl_ret = throw_for_errno(env, "exec() failed: ", helper_error[1]);
        } else if (helper_error[0] == COMM_ERR_CHDIR) {
          erl_ret = throw_for_errno(env, "chdir() failed: ", helper_error[1]);
        } else if (helper_error[0] == COMM_ERR_SETUID) {
          erl_ret = throw_for_errno(env, "setuid() failed: ", helper_error[1]);
        } else if (helper_error[0] == COMM_ERR_SETGID) {
          erl_ret = throw_for_errno(env, "setgid() failed: ", helper_error[1]);
        }
        goto done;
      }

      if (pty_nonblock(master) == -1) {
        erl_ret = nif::error(env, "Could not set master fd to nonblocking.");
        goto done;
      }

      pty_pipesocket * pipesocket = (pty_pipesocket *)enif_alloc_resource(pty_pipesocket::type, sizeof(pty_pipesocket));
      if (pipesocket == NULL) {
        erl_ret = nif::error(env, "Could not allocate memory for resource.");
        // todo: cleanup
        goto done;
      }

      bool success = false;
      ERL_NIF_TERM ptsname_ = nif::make_string(env, ptsname(master), success);
      ErlNifPid* process = (ErlNifPid *)enif_alloc(sizeof(ErlNifPid));
      process = enif_self(env, process);

      if (success) {
        pipesocket->fd = master;
        pipesocket->env = env;
        pipesocket->process = process;

        ERL_NIF_TERM pipe_socket = enif_make_resource(env, (void *)pipesocket);

        erl_ret = enif_make_tuple3(env, 
          pipe_socket,
          enif_make_int(env, pid),
          ptsname_
        );
      } else {
        erl_ret = nif::error(env, "Could not allocate memory for ptsname.");
        // todo: cleanup
        goto done;
      }

      uv_pipe_init(uv_default_loop(), &pipesocket->handle_, 0);
      int uv_err = uv_pipe_open(&pipesocket->handle_, master);
      if (uv_err != 0) {
        erl_ret = nif::error(env, "uv_pipe_open failed.");
        // todo: cleanup
        goto done;
      }

      pty_baton *baton = new pty_baton();
      baton->exit_code = 0;
      baton->signal_code = 0;
      baton->env = env;
      baton->process = process;
      baton->pid = pid;
      baton->async.data = baton;

      uv_mutex_init(&pipesocket->mutex);
      uv_async_init(uv_default_loop(), &pipesocket->async, pty_after_pipesocket);

      uv_async_init(uv_default_loop(), &baton->async, pty_after_waitpid);
      uv_thread_create(&baton->tid, pty_waitpid, static_cast<void*>(baton));
      uv_thread_create(&pipesocket->tid, pty_pipesocket_fn, static_cast<void*>(pipesocket));
    }
done:
    posix_spawn_file_actions_destroy(&acts);
    posix_spawnattr_destroy(&attrs);

    if (argv) {
      for (int i = 0; i < argl; i++) free(argv[i]);
      delete[] argv;
    }
    if (envs_c) {
      for (int i = 0; i < envc; i++) free(envs_c[i]);
      delete[] envs_c;
    }
  }

  return erl_ret;
}

static ERL_NIF_TERM expty_write(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
  ERL_NIF_TERM erl_ret;
  pty_pipesocket * pipesocket;
  if (enif_get_resource(env, argv[0], pty_pipesocket::type, (void **)&pipesocket)) {
    ErlNifBinary erl_bin;
    size_t nbytes = 0;
    if (enif_inspect_binary(env, argv[1], &erl_bin)) {
      nbytes = pipesocket->write(erl_bin.data, erl_bin.size);
    } else if (enif_inspect_iolist_as_binary(env, argv[1], &erl_bin)) {
      nbytes = pipesocket->write(erl_bin.data, erl_bin.size);
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

static ERL_NIF_TERM throw_for_errno(ErlNifEnv *env, const char* message, int _errno) {
  return nif::error(env, (
    message + std::string(strerror(_errno))
  ).c_str());
}

/**
 * Nonblocking FD
 */

static int
pty_nonblock(int fd) {
  int flags = fcntl(fd, F_GETFL, 0);
  if (flags == -1) return -1;
  return fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

static void
pty_pipesocket_fn(void *data) {
  pty_pipesocket *pipesocket = static_cast<pty_pipesocket*>(data);

  int fd = pipesocket->fd;
  fd_set readfds;
  FD_ZERO(&readfds);
  FD_SET(fd, &readfds);
  int activity;
  
  while (true) {
    activity = select(fd + 1 , &readfds , NULL , NULL , NULL);
    if ((activity < 0) && (errno != EINTR)) {
      printf("select error\r\n");
    }

    if (FD_ISSET(fd, &readfds)) {
      size_t bytes_read = 0;
      char buffer[1024] = {'\0'};
      bytes_read = read(fd, buffer, 1024);
      if (bytes_read == 0) {
        break;
      }

      ERL_NIF_TERM dataread;
      unsigned char * ptr;

      ErlNifEnv * msg_env = enif_alloc_env();
      if ((ptr = enif_make_new_binary(msg_env, bytes_read, &dataread)) != nullptr) {
        memcpy(ptr, buffer, bytes_read);
        enif_send(NULL, pipesocket->process, msg_env, enif_make_tuple2(msg_env, 
          nif::atom(msg_env, "data"),
          dataread
        ));
        enif_free_env(msg_env);
      } 
    }
  }
}

size_t pty_pipesocket::write(void * data, size_t len) {
  uv_mutex_lock(&this->mutex);
  size_t bytes_to_write = len, bytes_written = 0, buffer_size = 1024, nbytes = 0;
  size_t retry = 3;
  
  while (true) {
    nbytes = buffer_size;
    if (buffer_size > bytes_to_write) {
      nbytes = bytes_to_write;
    }

    ssize_t bytes_written_cur = ::write(this->fd, ((void *)(int64_t *)(((size_t)(char *)data) + bytes_written)), nbytes);
    if (bytes_written_cur > 0) {
      bytes_written += bytes_written_cur;
      bytes_to_write -= bytes_written_cur;
      if (bytes_written == len) {
        break;
      }
    } else {
      if (retry-- > 0) {
        usleep(10);
      }
    }
  }

  uv_mutex_unlock(&this->mutex);
  return bytes_written;
}

/**
 * pty_waitpid
 * Wait for SIGCHLD to read exit status.
 */

static void
pty_waitpid(void *data) {
  int ret;
  int stat_loc;

  pty_baton *baton = static_cast<pty_baton*>(data);

  errno = 0;

  if ((ret = waitpid(baton->pid, &stat_loc, 0)) != baton->pid) {
    if (ret == -1 && errno == EINTR) {
      return pty_waitpid(baton);
    }
    // if (ret == -1 && errno == ECHILD) {
    //   // XXX node v0.8.x seems to have this problem.
    //   // waitpid is already handled elsewhere.
    //   ;
    // } else {
    //   assert(false);
    // }
  }

  if (WIFEXITED(stat_loc)) {
    baton->exit_code = WEXITSTATUS(stat_loc); // errno?
  }

  if (WIFSIGNALED(stat_loc)) {
    baton->signal_code = WTERMSIG(stat_loc);
  }

  uv_async_send(&baton->async);
}

/**
 * pty_after_waitpid
 * Callback after exit status has been read.
 */

static void
pty_after_waitpid(uv_async_t *async) {
  pty_baton *baton = static_cast<pty_baton*>(async->data);

  if (enif_is_process_alive(baton->env, baton->process)) {
    ErlNifEnv * msg_env = enif_alloc_env();
    enif_send(NULL, baton->process, msg_env, enif_make_tuple3(msg_env, 
      nif::atom(msg_env, "exit"),
      enif_make_int(msg_env, baton->exit_code),
      enif_make_int(msg_env, baton->signal_code)
    ));
    enif_free_env(msg_env);
  }

  uv_close((uv_handle_t *)async, pty_after_close);
}

static void
pty_after_pipesocket(uv_async_t *async) {
  pty_pipesocket *pipesocket = static_cast<pty_pipesocket*>(async->data);
  uv_close((uv_handle_t *)async, pty_after_close_pipesocket);
}

/**
 * pty_after_close
 * uv_close() callback - free handle data
 */

static void
pty_after_close(uv_handle_t *handle) {
  uv_async_t *async = (uv_async_t *)handle;
  pty_baton *baton = static_cast<pty_baton*>(async->data);
  enif_free(baton->process);
  delete baton;
}

static void
pty_after_close_pipesocket(uv_handle_t *handle) {
  uv_async_t *async = (uv_async_t *)handle;
  pty_pipesocket *pipesocket = static_cast<pty_pipesocket*>(async->data);
  enif_free(pipesocket->process);
  uv_mutex_destroy(&pipesocket->mutex);
  enif_release_resource((void *)pipesocket);
  delete pipesocket;
}

/**
 * openpty(3) / forkpty(3)
 */

static int
pty_openpty(int *amaster,
            int *aslave,
            char *name,
            const struct termios *termp,
            const struct winsize *winp) {
#if defined(__sun)
  char *slave_name;
  int slave;
  int master = open("/dev/ptmx", O_RDWR | O_NOCTTY);
  if (master == -1) return -1;
  if (amaster) *amaster = master;

  if (grantpt(master) == -1) goto err;
  if (unlockpt(master) == -1) goto err;

  slave_name = ptsname(master);
  if (slave_name == NULL) goto err;
  if (name) strcpy(name, slave_name);

  slave = open(slave_name, O_RDWR | O_NOCTTY);
  if (slave == -1) goto err;
  if (aslave) *aslave = slave;

  ioctl(slave, I_PUSH, "ptem");
  ioctl(slave, I_PUSH, "ldterm");
  ioctl(slave, I_PUSH, "ttcompat");

  if (termp) tcsetattr(slave, TCSAFLUSH, termp);
  if (winp) ioctl(slave, TIOCSWINSZ, winp);

  return 0;

err:
  close(master);
  return -1;
#else
  return openpty(amaster, aslave, name, (termios *)termp, (winsize *)winp);
#endif
}

static void destruct(ErlNifEnv *env, void *args) {
    // pty_pipesocket * res = (pty_pipesocket *)args;
}

static int on_load(ErlNifEnv * env, void **, ERL_NIF_TERM) {
  ErlNifResourceType *rt;
  rt = enif_open_resource_type(env, "Elixir.ExPTY.Nif", "pty_pipesocket", destruct, ERL_NIF_RT_CREATE, NULL);
  if (!rt) return -1;
  pty_pipesocket::type = rt;
  return 0;
}

static int on_reload(ErlNifEnv *, void **, ERL_NIF_TERM) {
  return 0;
}

static int on_upgrade(ErlNifEnv *, void **, void **, ERL_NIF_TERM) {
  return 0;
}

static ErlNifFunc nif_functions[] = {
  {"spawn", 11, expty_spawn, ERL_NIF_DIRTY_JOB_IO_BOUND},
  {"write", 2, expty_write, ERL_NIF_DIRTY_JOB_IO_BOUND}
};

ERL_NIF_INIT(Elixir.ExPTY.Nif, nif_functions, on_load, on_reload, on_upgrade, NULL);
