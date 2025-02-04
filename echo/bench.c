/*
 * benchmark.c
 *
 * A benchmark client for the event‐driven echo server.
 *
 * Usage:
 *   ./benchmark <num_clients> <messages_per_client> <message_size>
 *
 * Each client thread:
 *   - connects to the echo server (assumed at 127.0.0.1:1234),
 *   - sends messages with a 4‐byte header (unsigned 32-bit length) followed by
 * a payload,
 *   - waits for the echoed response,
 *   - measures the round‐trip time per message.
 *
 * At the end, the program prints:
 *   - total messages sent,
 *   - average round‐trip latency (in microseconds),
 *   - throughput (messages per second).
 */

#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define SERVER_IP "127.0.0.1"
#define SERVER_PORT 6969

typedef struct {
  int id;
  int messages;
  int msg_size;         // size of payload (not including 4-byte header)
  long long total_usec; // total round-trip time (microseconds)
} client_args_t;

static inline long long get_usec(void) {
  struct timeval tv;
  gettimeofday(&tv, NULL);
  return ((long long)tv.tv_sec * 1000000LL + tv.tv_usec);
}

void *client_thread(void *arg) {
  client_args_t *args = (client_args_t *)arg;
  int sock;
  struct sockaddr_in serv_addr;

  // Create a TCP socket.
  if ((sock = socket(AF_INET, SOCK_STREAM, 0)) < 0) {
    perror("socket");
    pthread_exit((void *)1);
  }

  // Set up server address.
  memset(&serv_addr, 0, sizeof(serv_addr));
  serv_addr.sin_family = AF_INET;
  serv_addr.sin_port = htons(SERVER_PORT);
  if (inet_pton(AF_INET, SERVER_IP, &serv_addr.sin_addr) <= 0) {
    perror("inet_pton");
    close(sock);
    pthread_exit((void *)1);
  }

  // Connect to the server.
  if (connect(sock, (struct sockaddr *)&serv_addr, sizeof(serv_addr)) < 0) {
    perror("connect");
    close(sock);
    pthread_exit((void *)1);
  }

  // Allocate send and receive buffers.
  // The message format is: [4-byte length header][payload]
  int total_msg_size = 4 + args->msg_size;
  uint8_t *send_buf = malloc(total_msg_size);
  uint8_t *recv_buf = malloc(total_msg_size);
  if (!send_buf || !recv_buf) {
    perror("malloc");
    close(sock);
    free(send_buf);
    free(recv_buf);
    pthread_exit((void *)1);
  }

  // Set the 4-byte header to the payload length.
  uint32_t net_len = htonl(args->msg_size);
  memcpy(send_buf, &net_len, 4);
  // Fill the payload with a fixed pattern.
  memset(send_buf + 4, 'A' + (args->id % 26), args->msg_size);

  // Loop sending messages and waiting for echo.
  long long start_usec, end_usec;
  for (int i = 0; i < args->messages; i++) {
    start_usec = get_usec();
    int sent = 0;
    // Send the entire message.
    while (sent < total_msg_size) {
      int n = send(sock, send_buf + sent, total_msg_size - sent, 0);
      if (n <= 0) {
        perror("send");
        goto cleanup;
      }
      sent += n;
    }
    // Read echoed response.
    int recvd = 0;
    while (recvd < total_msg_size) {
      int n = recv(sock, recv_buf + recvd, total_msg_size - recvd, 0);
      if (n <= 0) {
        perror("recv");
        goto cleanup;
      }
      recvd += n;
    }
    end_usec = get_usec();
    args->total_usec += (end_usec - start_usec);

    // (Optional) verify echoed message:
    if (memcmp(send_buf, recv_buf, total_msg_size) != 0) {
      fprintf(stderr, "Thread %d: Mismatched echo at iteration %d\n", args->id,
              i);
    }
  }

cleanup:
  close(sock);
  free(send_buf);
  free(recv_buf);
  pthread_exit(NULL);
}

int main(int argc, char *argv[]) {
  if (argc != 4) {
    fprintf(stderr,
            "Usage: %s <num_clients> <messages_per_client> <message_size>\n",
            argv[0]);
    exit(EXIT_FAILURE);
  }
  int num_clients = atoi(argv[1]);
  int messages = atoi(argv[2]);
  int msg_size = atoi(argv[3]);
  if (num_clients <= 0 || messages <= 0 || msg_size <= 0) {
    fprintf(stderr, "Invalid arguments: all values must be positive\n");
    exit(EXIT_FAILURE);
  }

  pthread_t *threads = malloc(sizeof(pthread_t) * num_clients);
  client_args_t *args = malloc(sizeof(client_args_t) * num_clients);
  if (!threads || !args) {
    perror("malloc");
    exit(EXIT_FAILURE);
  }

  printf("Starting benchmark: %d clients, %d messages per client, %d-byte "
         "payload\n",
         num_clients, messages, msg_size);

  long long global_total_usec = 0;
  int total_messages = num_clients * messages;

  // Create client threads.
  for (int i = 0; i < num_clients; i++) {
    args[i].id = i;
    args[i].messages = messages;
    args[i].msg_size = msg_size;
    args[i].total_usec = 0;
    if (pthread_create(&threads[i], NULL, client_thread, &args[i]) != 0) {
      perror("pthread_create");
      exit(EXIT_FAILURE);
    }
  }

  // Wait for threads to finish.
  for (int i = 0; i < num_clients; i++) {
    pthread_join(threads[i], NULL);
    global_total_usec += args[i].total_usec;
  }

  // Calculate average round-trip latency and throughput.
  double avg_latency_usec = (double)global_total_usec / total_messages;
  double total_time_sec = (double)global_total_usec / 1000000.0;
  double throughput = total_messages / total_time_sec;

  printf("\n=== Benchmark Results ===\n");
  printf("Total messages: %d\n", total_messages);
  printf("Total round-trip time: %.3f sec\n", total_time_sec);
  printf("Average latency: %.3f usec per message\n", avg_latency_usec);
  printf("Throughput: %.0f messages per second\n", throughput);

  free(threads);
  free(args);
  return 0;
}
