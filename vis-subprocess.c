#include "util.h"

#include "vis-lua.h"
#include "vis-subprocess.h"

/* Pool of information about currently running subprocesses */
static Process *process_pool;

/**
 * Adds new empty process information structure to the process pool and
 * returns it
 * @return a new Process instance
 */
static Process *new_process_in_pool(void) {
	Process *newprocess = calloc(1, sizeof(Process));
	if (!newprocess) {
		return NULL;
	}
	newprocess->next = process_pool;
	process_pool = newprocess;
	return newprocess;
}

/**
 * Removes the subprocess information from the pool, sets invalidator to NULL
 * and frees resources.
 * @param target reference to the process to be removed
 * @return the next process in the pool
 */
static Process *destroy_process(Process *target) {
	if (target->outfd != -1) {
		close(target->outfd);
	}
	if (target->errfd != -1) {
		close(target->errfd);
	}
	if (target->inpfd != -1) {
		close(target->inpfd);
	}
	buffer_release(&target->input);
	/* marking the handle as closed for lua */
	if (target->owner) {
		*(target->owner) = NULL;
	}
	Process *next = target->next;
	free(target->name);
	free(target);

	return next;
}

/**
 * Starts new subprocess by passing the `command` to the shell and
 * returns the subprocess information structure, containing file descriptors
 * of the process.
 * Also stores the subprocess information to the internal pool to track
 * its status and responses.
 * @param vis the editor instance
 * @param name a string that contains a unique name for the subprocess.
 * This name will be passed to the PROCESS_RESPONSE event handler
 * to distinguish running subprocesses.
 * @param command a command to be executed to spawn a process
 * @param owner the handle's pointer to the process; it is set to NULL when
 * the process dies. vis_process_release drops the handle and has the
 * process killed on the next main loop iteration.
 */
Process *vis_process_communicate(Vis *vis, const char *name,
                                 const char *command, Process **owner) {
	int pin[2], pout[2], perr[2];
	pid_t pid = (pid_t)-1;
	if (pipe(perr) == -1) {
		goto closeerr;
	}
	if (pipe(pout) == -1) {
		goto closeouterr;
	}
	if (pipe(pin) == -1) {
		goto closeall;
	}
	pid = fork();
	if (pid == -1) {
		vis_info_show(vis, "fork failed: %s", strerror(errno));
	} else if (pid == 0) { /* child process */
		sigset_t sigterm_mask;
		sigemptyset(&sigterm_mask);
		sigaddset(&sigterm_mask, SIGTERM);
		if (sigprocmask(SIG_UNBLOCK, &sigterm_mask, NULL) == -1) {
			fprintf(stderr, "failed to reset signal mask");
			exit(EXIT_FAILURE);
		}
		dup2(pin[0], STDIN_FILENO);
		dup2(pout[1], STDOUT_FILENO);
		dup2(perr[1], STDERR_FILENO);
	} else { /* main process */
		Process *new = new_process_in_pool();
		if (!new) {
			vis_info_show(vis, "Cannot create process: %s", strerror(errno));
			goto closeall;
		}
		new->name = strdup(name);
		if (!new->name) {
			vis_info_show(vis, "Cannot copy process name: %s", strerror(errno));
			/* pop top element (which is `new`) from the pool */
			process_pool = destroy_process(process_pool);
			goto closeall;
		}
		new->outfd = pout[0];
		new->errfd = perr[0];
		new->inpfd = pin[1];
		new->pid = pid;
		new->owner = owner;
		/* writes go through the queue so the editor never waits on a child
		 * that has stopped reading, which a language server does whenever
		 * its own output pipe to us is full */
		fcntl(new->inpfd, F_SETFL, fcntl(new->inpfd, F_GETFL) | O_NONBLOCK);
		close(pin[0]);
		close(pout[1]);
		close(perr[1]);
		return new;
	}
closeall:
	close(pin[0]);
	close(pin[1]);
closeouterr:
	close(pout[0]);
	close(pout[1]);
closeerr:
	close(perr[0]);
	close(perr[1]);
	if (pid == 0) { /* start command in child process */
		execlp(vis->shell, vis->shell, "-c", command, (char*)NULL);
		fprintf(stderr, "exec failed: %s(%d)\n", strerror(errno), errno);
		exit(1);
	} else {
		vis_info_show(vis, "process creation failed: %s", strerror(errno));
	}
	return NULL;
}

/**
 * Writes as much of the queued input as the pipe accepts right now.
 * A failed write closes the pipe; the queue is dropped with it.
 * @param current the process whose queue to flush
 */
static void flush_input(Process *current) {
	while (current->inpfd != -1 && current->input.length > 0) {
		ssize_t written = write(current->inpfd, current->input.data, current->input.length);
		if (written > 0) {
			buffer_remove(&current->input, 0, written);
		} else if (written == -1 && errno == EINTR) {
			continue;
		} else if (written == -1 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
			break;
		} else {
			close(current->inpfd);
			current->inpfd = -1;
			buffer_release(&current->input);
		}
	}
}

/**
 * Queues data for the subprocess's stdin and sends what fits at once;
 * the rest goes out from the main loop as the pipe drains.
 * @param current the process to write to
 * @param data the bytes to send
 * @param len the number of bytes
 * @return false if the pipe is closed, which a failed write also causes
 */
bool vis_process_write(Process *current, const char *data, size_t len) {
	if (current->inpfd == -1)
		return false;
	if (!buffer_append(&current->input, data, len))
		return false;
	flush_input(current);
	return current->inpfd != -1;
}

/**
 * Drops the handle's reference: sends what is still queued if the pipe
 * takes it, closes the process's stdin and marks it to be killed on the
 * next main loop iteration.
 * @param current the process to release, NULL if it already died
 */
void vis_process_release(Process *current) {
	if (!current)
		return;
	flush_input(current);
	if (current->inpfd != -1) {
		close(current->inpfd);
		current->inpfd = -1;
	}
	buffer_release(&current->input);
	current->owner = NULL;
	current->release = true;
}

/**
 * Adds file descriptors of currently running subprocesses to the `readfds`
 * and, for those with queued input, to the `writefds`, to track their
 * readiness, and returns the maximum file descriptor value to pass it to
 * the `pselect` call
 * @param readfds the structure for `pselect` call to fill
 * @param writefds the structure for `pselect` call to fill
 * @return maximum file descriptor number in the structures
 */
int vis_process_before_tick(fd_set *readfds, fd_set *writefds) {
	int maxfd = 0;
	for (Process **pointer = &process_pool; *pointer; pointer = &((*pointer)->next)) {
		Process *current = *pointer;
		if (current->outfd != -1) {
			FD_SET(current->outfd, readfds);
			maxfd = maxfd < current->outfd ? current->outfd : maxfd;
		}
		if (current->errfd != -1) {
			FD_SET(current->errfd, readfds);
			maxfd = maxfd < current->errfd ? current->errfd : maxfd;
		}
		if (current->inpfd != -1 && current->input.length > 0) {
			FD_SET(current->inpfd, writefds);
			maxfd = maxfd < current->inpfd ? current->inpfd : maxfd;
		}
	}
	return maxfd;
}

/**
 * Reads data from the given subprocess file descriptor `fd` and fires
 * the PROCESS_RESPONSE event in Lua with given subprocess `name`,
 * `rtype` and the read data as arguments.
 * @param vis the editor instance
 * @param fd the file descriptor to read data from
 * @param name a name of the subprocess
 * @param rtype a type of file descriptor where the new data is found
 */
static void read_and_fire(Vis* vis, int fd, const char *name, ResponseType rtype) {
	static char buffer[PIPE_BUF];
	size_t obtained = read(fd, &buffer, PIPE_BUF-1);
	if (obtained > 0) {
		vis_lua_process_response(vis, name, buffer, obtained, rtype);
	}
}

/**
 * Checks if a subprocess is dead or needs to be killed then raises an event
 * or kills it if necessary.
 * @param vis the editor instance
 * @param current the process to wait for or kill
 * @return true if the process is dead
 */
static bool wait_or_kill_process(Vis *vis, Process *current) {
	int status;
	pid_t wpid = waitpid(current->pid, &status, WNOHANG);
	if (wpid == -1) {
		vis_message_show(vis, strerror(errno));
	} else if (wpid == current->pid) {
		goto just_destroy;
	} else if (current->release) {
		goto kill_and_destroy;
	}
	return false;

kill_and_destroy:
	kill(current->pid, SIGTERM);
	waitpid(current->pid, &status, 0);
just_destroy:
	if (WIFSIGNALED(status)) {
		vis_lua_process_response(vis, current->name, NULL, WTERMSIG(status), SIGNAL);
	} else {
		vis_lua_process_response(vis, current->name, NULL, WEXITSTATUS(status), EXIT);
	}
	return true;
}

/**
 * Checks if `readfds` contains file descriptors of subprocesses from
 * the pool. If so, it reads their data and fires corresponding events.
 * Queued input goes out to the processes whose stdin `writefds` reports
 * writable. Also checks if each subprocess from the pool is dead or needs
 * to be killed then raises an event or kills it if necessary.
 * @param vis the editor instance
 * @param readfds the structure for `pselect` call with file descriptors
 * @param writefds the structure for `pselect` call with file descriptors
 */
void vis_process_tick(Vis *vis, fd_set *readfds, fd_set *writefds) {
	for (Process **pointer = &process_pool; *pointer; ) {
		Process *current = *pointer;
		if (current->inpfd != -1 && FD_ISSET(current->inpfd, writefds)) {
			flush_input(current);
		}
		if (current->outfd != -1 && FD_ISSET(current->outfd, readfds)) {
			read_and_fire(vis, current->outfd, current->name, STDOUT);
		}
		if (current->errfd != -1 && FD_ISSET(current->errfd, readfds)) {
			read_and_fire(vis, current->errfd, current->name, STDERR);
		}
		if (!wait_or_kill_process(vis, current)) {
			pointer = &current->next;
		} else {
			/* update our iteration pointer */
			*pointer = destroy_process(current);
		}
	}
}

/**
 * Checks if each subprocess from the pool is dead or needs to be
 * killed then raises an event or kills it if necessary.
 */
void vis_process_waitall(Vis *vis) {
	for (Process **pointer = &process_pool; *pointer; ) {
		Process *current = *pointer;
		if (!wait_or_kill_process(vis, current)) {
			pointer = &current->next;
		} else {
			/* update our iteration pointer */
			*pointer = destroy_process(current);
		}
	}
}
