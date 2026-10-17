#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <mqueue.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ipc.h>
#include <sys/msg.h>
#include <sys/sem.h>
#include <sys/shm.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* Run explicitly after a temporary module load. No root or policy changes. */
union sem_value { int val; struct semid_ds *buf; unsigned short *array; };

static int ipc_check(void)
{
    int result = 1, msg = -1, sem = -1, shm = -1;
    void *memory = (void *)-1;
    mqd_t mq = (mqd_t)-1;
    char queue[64], received[32] = {0};
    struct { long type; char text[16]; } sent = {1, "y70-ipc-ok"}, got = {0};
    struct sembuf op = {0, -1, IPC_NOWAIT};
    union sem_value value = {.val = 2};
    struct mq_attr attr = {.mq_maxmsg = 4, .mq_msgsize = 32};

    alarm(15);
    if (unshare(CLONE_NEWIPC) != 0) { perror("unshare NEWIPC"); return 1; }
    puts("PASS unshare NEWIPC");
    msg = msgget(IPC_PRIVATE, IPC_CREAT | 0600);
    if (msg < 0 || msgsnd(msg, &sent, sizeof(sent.text), IPC_NOWAIT) != 0 ||
        msgrcv(msg, &got, sizeof(got.text), 1, IPC_NOWAIT) != (ssize_t)sizeof(got.text) ||
        memcmp(got.text, sent.text, sizeof(sent.text)) != 0) {
        perror("SysV message queue"); goto done;
    }
    puts("PASS SysV message queue send/receive");
    sem = semget(IPC_PRIVATE, 1, IPC_CREAT | 0600);
    if (sem < 0 || semctl(sem, 0, SETVAL, value) != 0 || semop(sem, &op, 1) != 0 ||
        semctl(sem, 0, GETVAL) != 1) {
        perror("SysV semaphore"); goto done;
    }
    puts("PASS SysV semaphore set/op/get");
    shm = shmget(IPC_PRIVATE, 4096, IPC_CREAT | 0600);
    if (shm < 0 || (memory = shmat(shm, NULL, 0)) == (void *)-1) {
        perror("SysV shared memory attach"); goto done;
    }
    memcpy(memory, sent.text, sizeof(sent.text));
    if (memcmp(memory, sent.text, sizeof(sent.text)) != 0) goto done;
    puts("PASS SysV shared memory attach/read/write");
    snprintf(queue, sizeof(queue), "/droidspaces-check-%ld", (long)getpid());
    mq = mq_open(queue, O_CREAT | O_EXCL | O_RDWR | O_NONBLOCK, 0600, &attr);
    if (mq == (mqd_t)-1 || mq_send(mq, sent.text, sizeof(sent.text), 0) != 0 ||
        mq_receive(mq, received, sizeof(received), NULL) != (ssize_t)sizeof(sent.text) ||
        memcmp(received, sent.text, sizeof(sent.text)) != 0) {
        perror("POSIX message queue"); goto done;
    }
    puts("PASS POSIX message queue open/send/receive");
    result = 0;
done:
    if (mq != (mqd_t)-1) {
        if (mq_close(mq) != 0) { perror("mq_close"); result = 1; }
        if (mq_unlink(queue) != 0) { perror("mq_unlink"); result = 1; }
    }
    if (memory != (void *)-1 && shmdt(memory) != 0) { perror("shmdt"); result = 1; }
    if (shm >= 0 && shmctl(shm, IPC_RMID, NULL) != 0) { perror("shmctl RMID"); result = 1; }
    if (sem >= 0 && semctl(sem, 0, IPC_RMID) != 0) { perror("semctl RMID"); result = 1; }
    if (msg >= 0 && msgctl(msg, IPC_RMID, NULL) != 0) { perror("msgctl RMID"); result = 1; }
    if (!result) puts("PASS IPC object cleanup");
    return result;
}

static int pid_check(void)
{
    pid_t child;
    int status;
    alarm(15);
    if (unshare(CLONE_NEWPID) != 0) { perror("unshare NEWPID"); return 1; }
    puts("PASS unshare NEWPID");
    fflush(NULL);
    child = fork();
    if (child < 0) { perror("fork"); return 1; }
    if (child == 0) {
        pid_t self = getpid();
        printf("PID namespace child pid=%ld\n", (long)self);
        fflush(NULL);
        _exit(self == 1 ? 0 : 1);
    }
    if (waitpid(child, &status, 0) != child) { perror("waitpid"); return 1; }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return 1;
    puts("PASS PID namespace child init and parent wait");
    return 0;
}

int main(int argc, char **argv)
{
    setvbuf(stdout, NULL, _IONBF, 0);
    if (argc == 2 && strcmp(argv[1], "--ipc") == 0) return ipc_check();
    if (argc == 2 && strcmp(argv[1], "--pid") == 0) return pid_check();
    fprintf(stderr, "Usage: droidspaces-check --ipc|--pid\n");
    return 2;
}
