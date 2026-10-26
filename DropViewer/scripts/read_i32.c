#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Lua calls these as C functions. The argument is lua_State*, which this
   module never touches. Returning 0 means no Lua results. */

#define PIN_FROM_ADDRESS 0x04
#define PIN_MODULE 0x01

__declspec(dllimport) BOOL WINAPI GetModuleHandleExA(DWORD flags, LPCSTR address, HMODULE *module);

typedef struct DropJob {
    char request[MAX_PATH];
    char result[MAX_PATH];
} DropJob;

static volatile LONG drop_busy = 0;

static void pin_module(void)
{
    static LONG pinned = 0;
    HMODULE module = NULL;

    if (InterlockedCompareExchange(&pinned, 1, 0) != 0) {
        return;
    }
    GetModuleHandleExA(PIN_FROM_ADDRESS | PIN_MODULE, (LPCSTR)pin_module, &module);
}

static int cache_dir(char *out, size_t cap)
{
    char base[MAX_PATH];
    DWORD n;
    int wrote;

    n = GetEnvironmentVariableA("LOCALAPPDATA", base, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) {
        return 0;
    }
    wrote = _snprintf(out, cap, "%s\\Drop Viewer", base);
    return wrote > 0 && (size_t)wrote < cap;
}

static void publish(const char *result_path, const char *text)
{
    char temp_path[MAX_PATH];
    FILE *out;
    int n;

    n = _snprintf(temp_path, MAX_PATH, "%s.tmp", result_path);
    if (n < 0 || n >= MAX_PATH) {
        return;
    }
    out = fopen(temp_path, "wb");
    if (!out) {
        return;
    }
    fputs(text, out);
    fclose(out);
    MoveFileExA(temp_path, result_path, MOVEFILE_REPLACE_EXISTING);
}

static void strip_line(char *line)
{
    size_t n = strlen(line);
    while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r' || line[n - 1] == ' ')) {
        line[--n] = 0;
    }
}

static int read_job(DropJob *job)
{
    char dir[MAX_PATH];
    char path[MAX_PATH];
    FILE *file;

    if (!cache_dir(dir, sizeof(dir))) {
        return 0;
    }
    if (_snprintf(path, sizeof(path), "%s\\job.txt", dir) < 0) {
        return 0;
    }
    file = fopen(path, "rb");
    if (!file) {
        return 0;
    }
    if (!fgets(job->request, MAX_PATH, file) || !fgets(job->result, MAX_PATH, file)) {
        fclose(file);
        return 0;
    }
    fclose(file);
    strip_line(job->request);
    strip_line(job->result);
    return job->request[0] != 0 && job->result[0] != 0;
}

static DWORD WINAPI worker(LPVOID param)
{
    DropJob *job = (DropJob *)param;
    FILE *in;
    long long data = 0;
    long long addresses[512];
    int values[512];
    int count = 0;
    int i;
    char *text;
    size_t cap;
    HANDLE process;
    SIZE_T got;

    in = fopen(job->request, "rb");
    if (!in) {
        publish(job->result, "err\nrequest\n");
        goto done;
    }
    if (fscanf(in, "%lld %d", &data, &count) != 2 || count < 0 || count > 512) {
        fclose(in);
        publish(job->result, "err\nrequest\n");
        goto done;
    }
    for (i = 0; i < count; i++) {
        if (fscanf(in, "%lld", &addresses[i]) != 1) {
            fclose(in);
            publish(job->result, "err\nrequest\n");
            goto done;
        }
    }
    fclose(in);

    process = GetCurrentProcess();
    for (i = 0; i < count; i++) {
        got = 0;
        if (!ReadProcessMemory(process, (LPCVOID)(ULONG_PTR)addresses[i], &values[i], 4, &got) || got != 4) {
            publish(job->result, "err\nread\n");
            goto done;
        }
    }

    cap = (size_t)count * 16 + 64;
    text = (char *)malloc(cap);
    if (!text) {
        publish(job->result, "err\nmemory\n");
        goto done;
    }
    {
        int used = _snprintf(text, cap, "ok\n%lld\n%d\n", data, count);
        for (i = 0; i < count && used > 0 && (size_t)used < cap; i++) {
            used += _snprintf(text + used, cap - (size_t)used, "%d\n", values[i]);
        }
        if (used < 0 || (size_t)used >= cap) {
            free(text);
            publish(job->result, "err\nformat\n");
            goto done;
        }
    }
    publish(job->result, text);
    free(text);

done:
    free(job);
    InterlockedExchange(&drop_busy, 0);
    return 0;
}

__declspec(dllexport) int UnitDropsPrepare(void *lua_state)
{
    char dir[MAX_PATH];

    (void)lua_state;
    pin_module();
    if (cache_dir(dir, sizeof(dir))) {
        CreateDirectoryA(dir, NULL);
    }
    return 0;
}

__declspec(dllexport) int UnitDropsStart(void *lua_state)
{
    DropJob *job;
    HANDLE thread;

    (void)lua_state;
    pin_module();
    if (InterlockedCompareExchange(&drop_busy, 1, 0) != 0) {
        return 0;
    }
    job = (DropJob *)malloc(sizeof(*job));
    if (!job || !read_job(job)) {
        free(job);
        InterlockedExchange(&drop_busy, 0);
        return 0;
    }
    thread = CreateThread(NULL, 0, worker, job, 0, NULL);
    if (!thread) {
        free(job);
        InterlockedExchange(&drop_busy, 0);
        return 0;
    }
    CloseHandle(thread);
    return 0;
}
