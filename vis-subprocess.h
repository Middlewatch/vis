#ifndef VIS_SUBPROCESS_H
#define VIS_SUBPROCESS_H
#include "vis-core.h"
#include "vis-lua.h"

typedef struct Process Process;

struct Process {
	char *name;
	int outfd;
	int errfd;
	int inpfd;
	pid_t pid;
	Buffer input;    /* bytes queued for inpfd, written as the pipe accepts them */
	Process **owner; /* the handle's pointer to this process, cleared when it is destroyed */
	bool release;    /* the handle was closed: kill the process at the next tick */
	Process *next;
};

typedef enum { STDOUT, STDERR, SIGNAL, EXIT } ResponseType;

VIS_INTERNAL Process *vis_process_communicate(Vis *, const char *name, const char *command,
                                              Process **owner);
VIS_INTERNAL bool vis_process_write(Process *, const char *data, size_t len);
VIS_INTERNAL void vis_process_release(Process *);
VIS_INTERNAL int vis_process_before_tick(fd_set *readfds, fd_set *writefds);
VIS_INTERNAL void vis_process_tick(Vis *, fd_set *readfds, fd_set *writefds);
VIS_INTERNAL void vis_process_waitall(Vis *);
#endif
