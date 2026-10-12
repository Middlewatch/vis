/* Recovery journal: the unsaved text of a named file, written to
 * $XDG_STATE_HOME/vis/recovery/<path with / as %> on every undo snapshot
 * and removed when the file is saved or deliberately dropped, so a crash
 * or a lost terminal costs at most the last edit burst. See doc/adr/0001.
 */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

/* files above this are not journaled */
#define VIS_RECOVERY_MAX_SIZE (8u << 20)

static bool recovery_dir(char *buf, size_t n, bool create) {
	const char *state = getenv("XDG_STATE_HOME");
	int len;
	if (state && *state) {
		len = snprintf(buf, n, "%s/vis/recovery", state);
	} else {
		const char *home = getenv("HOME");
		if (!home)
			return false;
		len = snprintf(buf, n, "%s/.local/state/vis/recovery", home);
	}
	if (len < 0 || (size_t)len >= n)
		return false;
	if (create) {
		/* mkdir -p: every component, EEXIST being the usual answer */
		for (char *p = buf + 1; *p; p++) {
			if (*p == '/') {
				*p = '\0';
				mkdir(buf, 0700);
				*p = '/';
			}
		}
		if (mkdir(buf, 0700) == -1 && errno != EEXIST)
			return false;
	}
	return true;
}

/* the journal path of a named, non-internal file */
static bool recovery_path(File *file, char *buf, size_t n, bool create) {
	if (file->internal || file->filepath.length == 0)
		return false;
	if (!recovery_dir(buf, n, create))
		return false;
	size_t len = strlen(buf);
	if (len + 1 + (size_t)file->filepath.length + 1 > n)
		return false;
	buf[len++] = '/';
	for (ptrdiff_t i = 0; i < file->filepath.length; i++) {
		char c = (char)file->filepath.data[i];
		buf[len++] = c == '/' ? '%' : c;
	}
	buf[len] = '\0';
	return true;
}

bool vis_recovery_exists(Vis *vis, File *file) {
	char path[PATH_MAX];
	struct stat st;
	return recovery_path(file, path, sizeof path, false) &&
	       stat(path, &st) == 0 && st.st_size > 0;
}

void vis_recovery_remove(Vis *vis, File *file) {
	char path[PATH_MAX];
	if (recovery_path(file, path, sizeof path, false))
		unlink(path);
	file->recovery_dirty = false;
}

/* write the journal when the text changed since the last one; a text back
 * at its saved state has no journal, so undo to it removes a stale one */
void vis_recovery_write(Vis *vis, File *file) {
	if (!file->recovery_dirty || file->internal || file->filepath.length == 0)
		return;
	Text *txt = file->text;
	if (!text_modified(txt)) {
		vis_recovery_remove(vis, file);
		return;
	}
	size_t size = text_size(txt);
	if (size > VIS_RECOVERY_MAX_SIZE)
		return;

	char path[PATH_MAX], tmp[PATH_MAX];
	bool ok = recovery_path(file, path, sizeof path, true) &&
	          snprintf(tmp, sizeof tmp, "%s.tmp", path) < (int)sizeof tmp;
	int fd = ok ? open(tmp, O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC, 0600) : -1;
	if (fd != -1) {
		ssize_t written = text_write_range(txt, text_range_new(0, size), fd);
		ok = written == (ssize_t)size;
		if (close(fd) != 0)
			ok = false;
		if (ok)
			ok = rename(tmp, path) == 0;
		if (!ok)
			unlink(tmp);
	} else {
		ok = false;
	}

	if (ok) {
		file->recovery_dirty = false;
	} else if (!file->recovery_failed) {
		file->recovery_failed = true;
		vis_info_show(vis, "Recovery journal not written for %.*s: %s",
		              (int)file->name.length, file->name.data, strerror(errno));
	}
}

/* replace the file's text with the journal; the file is then modified
 * and :w makes the recovery permanent */
bool vis_recovery_load(Vis *vis, File *file) {
	char path[PATH_MAX];
	if (!recovery_path(file, path, sizeof path, false))
		return false;
	int fd = open(path, O_RDONLY|O_CLOEXEC);
	if (fd == -1)
		return false;
	struct stat st;
	if (fstat(fd, &st) == -1 || st.st_size < 0) {
		close(fd);
		return false;
	}
	size_t len = (size_t)st.st_size;
	char *data = malloc(len ? len : 1);
	if (!data) {
		close(fd);
		return false;
	}
	size_t got = 0;
	while (got < len) {
		ssize_t r = read(fd, data + got, len - got);
		if (r <= 0)
			break;
		got += (size_t)r;
	}
	close(fd);

	bool ok = got == len;
	if (ok) {
		Text *txt = file->text;
		ok = text_delete(txt, 0, text_size(txt)) &&
		     (len == 0 || text_insert(vis, txt, 0, data, len));
	}
	free(data);
	return ok;
}
