
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define SERVER_PORT 1234
#define SERVER_ADDR "127.0.0.1"
#define BUFFER_SIZE 1024

typedef struct {
  int id;
} client_arg_t;

void *client_thread(void *arg) {
  client_arg_t *clientArg = (client_arg_t *)arg;
  int id = clientArg->id;
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

  // Setup server address struct
  memset(&server_addr, 0, sizeof(server_addr));
  server_addr.sin_family = AF_INET;
  server_addr.sin_port = htons(SERVER_PORT);
  if (inet_pton(AF_INET, SERVER_ADDR, &server_addr.sin_addr) <= 0) {
    perror("inet_pton");
    close(sockfd);
    pthread_exit(NULL);
  }

  // Connect to server
  if (connect(sockfd, (struct sockaddr *)&server_addr, sizeof(server_addr)) <
      0) {
    perror("connect");
    close(sockfd);
    pthread_exit(NULL);
  }

  // Prepare message
  snprintf(send_buf, sizeof(send_buf), "Hello from client %d", id);
  size_t len = strlen(send_buf);

  // Send message
  ret = write(sockfd, send_buf, len);
  if (ret != (int)len) {
    perror("write");
    close(sockfd);
    pthread_exit(NULL);
  }

  // Read echoed response
  total = 0;
  while (total < (int)len) {
    nbytes = read(sockfd, recv_buf + total, len - total);
    if (nbytes < 0) {
      perror("read");
      close(sockfd);
      pthread_exit(NULL);
    } else if (nbytes == 0) {
      break;
    }
    total += nbytes;
  }
  recv_buf[total] = '\0';

  // Validate the echoed message
  if (total == (int)len && strcmp(send_buf, recv_buf) == 0) {
    printf("Client %d: Success. Echoed: \"%s\"\n", id, recv_buf);
  } else {
    printf("Client %d: Mismatch. Sent: \"%s\", Received: \"%s\"\n", id,
           send_buf, recv_buf);
  }

  close(sockfd);
  pthread_exit(NULL);
}

int main(int argc, char *argv[]) {
  int num_clients = 10; // default number of clients
  if (argc == 2) {
    num_clients = atoi(argv[1]);
    if (num_clients <= 0) {
      fprintf(stderr, "Invalid number of clients.\n");
      exit(EXIT_FAILURE);
    }
  }

  pthread_t *threads = malloc(num_clients * sizeof(pthread_t));
  if (!threads) {
    perror("malloc");
    exit(EXIT_FAILURE);
  }
  client_arg_t *args = malloc(num_clients * sizeof(client_arg_t));
  if (!args) {
    perror("malloc");
    free(threads);
    exit(EXIT_FAILURE);
  }

  // Spawn client threads
  for (int i = 0; i < num_clients; i++) {
    args[i].id = i;
    if (pthread_create(&threads[i], NULL, client_thread, &args[i]) != 0) {
      perror("pthread_create");
      // Optionally handle cleanup here
    }
  }

  // Wait for all threads to complete
  for (int i = 0; i < num_clients; i++) {
    pthread_join(threads[i], NULL);
  }

  free(threads);
  free(args);

  return 0;
}
