#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define SERVER_PORT 1234
#define SERVER_ADDR "127.0.0.1"
#define BUFFER_SIZE 1024

typedef struct {
  int id;
  int num_messages; // number of messages to send in this thread
} bench_arg_t;

void *bench_thread(void *arg) {
  bench_arg_t *benchArg = (bench_arg_t *)arg;
  int id = benchArg->id;
  int num_messages = benchArg->num_messages;
  int sockfd;
  struct sockaddr_in server_addr;
  char send_buf[BUFFER_SIZE];
  char recv_buf[BUFFER_SIZE];
  int ret, total, nbytes;

  // Create socket
  if ((sockfd = socket(AF_INET, SOCK_STREAM, 0)) < 0) {
    perror("socket");
    pthread_exit(NULL);
  }

  // Setup server address structure
  memset(&server_addr, 0, sizeof(server_addr));
  server_addr.sin_family = AF_INET;
  server_addr.sin_port = htons(SERVER_PORT);
  if (inet_pton(AF_INET, SERVER_ADDR, &server_addr.sin_addr) <= 0) {
    perror("inet_pton");
    close(sockfd);
    pthread_exit(NULL);
  }

  // Connect to the server
  if (connect(sockfd, (struct sockaddr *)&server_addr, sizeof(server_addr)) <
      0) {
    perror("connect");
    close(sockfd);
    pthread_exit(NULL);
  }

  // For each message, send and then wait for the echo reply
  for (int i = 0; i < num_messages; i++) {
    // Prepare a unique message per iteration.
    snprintf(send_buf, sizeof(send_buf), "Client %d: message %d", id, i);
    size_t len = strlen(send_buf);

    // Send the message
    ret = write(sockfd, send_buf, len);
    if (ret != (int)len) {
      perror("write");
      close(sockfd);
      pthread_exit(NULL);
    }

    // Read the echoed response
    total = 0;
    while (total < (int)len) {
      nbytes = read(sockfd, recv_buf + total, len - total);
      if (nbytes < 0) {
        perror("read");
        close(sockfd);
        pthread_exit(NULL);
      } else if (nbytes == 0) {
        fprintf(stderr, "Server closed connection prematurely\n");
        close(sockfd);
        pthread_exit(NULL);
      }
      total += nbytes;
    }
    recv_buf[total] = '\0';

    // Validate the echoed message
    if (strcmp(send_buf, recv_buf) != 0) {
      fprintf(stderr, "Mismatch: Sent \"%s\", Received \"%s\"\n", send_buf,
              recv_buf);
    }
  }

  close(sockfd);
  pthread_exit(NULL);
}

int main(int argc, char *argv[]) {
  int num_clients = 100;          // default number of concurrent clients
  int messages_per_client = 1000; // default number of messages per client

  if (argc >= 2) {
    num_clients = atoi(argv[1]);
    if (num_clients <= 0) {
      fprintf(stderr, "Invalid number of clients.\n");
      exit(EXIT_FAILURE);
    }
  }

  if (argc >= 3) {
    messages_per_client = atoi(argv[2]);
    if (messages_per_client <= 0) {
      fprintf(stderr, "Invalid number of messages per client.\n");
      exit(EXIT_FAILURE);
    }
  }

  pthread_t *threads = malloc(num_clients * sizeof(pthread_t));
  if (!threads) {
    perror("malloc");
    exit(EXIT_FAILURE);
  }
  bench_arg_t *args = malloc(num_clients * sizeof(bench_arg_t));
  if (!args) {
    perror("malloc");
    free(threads);
    exit(EXIT_FAILURE);
  }

  struct timeval start, end;
  // Record start time
  gettimeofday(&start, NULL);

  // Spawn benchmark threads
  for (int i = 0; i < num_clients; i++) {
    args[i].id = i;
    args[i].num_messages = messages_per_client;
    if (pthread_create(&threads[i], NULL, bench_thread, &args[i]) != 0) {
      perror("pthread_create");
      // Optionally handle cleanup here
    }
  }

  // Wait for all threads to complete
  for (int i = 0; i < num_clients; i++) {
    pthread_join(threads[i], NULL);
  }

  // Record end time
  gettimeofday(&end, NULL);

  // Calculate elapsed time in seconds
  double elapsed =
      (end.tv_sec - start.tv_sec) + (end.tv_usec - start.tv_usec) / 1e6;
  int total_messages = num_clients * messages_per_client;
  double throughput = total_messages / elapsed;

  printf("Benchmark Results:\n");
  printf("  Total messages sent: %d\n", total_messages);
  printf("  Total time: %.3f seconds\n", elapsed);
  printf("  Throughput: %.2f messages/second\n", throughput);

  free(threads);
  free(args);
  return 0;
}
