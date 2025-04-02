#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define SERVER_IP "127.0.0.1"
#define SERVER_PORT 1234
#define BUFFER_SIZE 128

int main() {
  int sockfd;
  struct sockaddr_in server_addr;
  char buffer[BUFFER_SIZE];

  // Create socket
  sockfd = socket(AF_INET, SOCK_STREAM, 0);
  if (sockfd < 0) {
    perror("Socket creation failed");
    return 1;
  }

  // Configure server address struct
  server_addr.sin_family = AF_INET;
  server_addr.sin_port = htons(SERVER_PORT);
  inet_pton(AF_INET, SERVER_IP, &server_addr.sin_addr);

  // Connect to server
  if (connect(sockfd, (struct sockaddr *)&server_addr, sizeof(server_addr)) <
      0) {
    perror("Connection failed");
    close(sockfd);
    return 1;
  }

  // Message to send
  const char *msg = "SET-KEY-VALUE";
  uint8_t len = strlen(msg); // Length as a single byte

  // Prepare buffer with protocol format {len}{msg}
  buffer[0] = len;
  memcpy(buffer + 1, msg, len);

  // Send the message
  if (send(sockfd, buffer, len + 1, 0) < 0) {
    perror("Send failed");
    close(sockfd);
    return 1;
  }

  // Receive response
  int bytes_received = recv(sockfd, buffer, BUFFER_SIZE, 0);
  if (bytes_received < 0) {
    perror("Receive failed");
    close(sockfd);
    return 1;
  }

  // Extract length from the received data
  uint8_t received_len = buffer[0];

  // Print response
  printf("Server echoed: %.*s\n", received_len, buffer + 1);
  printf("Echoed length: %d\n", received_len);

  // Close socket
  close(sockfd);
  return 0;
}
