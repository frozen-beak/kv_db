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
  uint32_t len = strlen(msg);    // Changed to 32-bit integer
  uint32_t net_len = htonl(len); // Convert to network byte order

  // Prepare buffer with protocol format {4-byte-len}{msg}
  memcpy(buffer, &net_len, 4);  // Copy 4-byte length header
  memcpy(buffer + 4, msg, len); // Copy message body

  // Send the message (4 header bytes + message length)
  if (send(sockfd, buffer, 4 + len, 0) < 0) {
    perror("Send failed");
    close(sockfd);
    return 1;
  }

  // Receive response (4-byte header first)
  uint32_t echoed_len;
  if (recv(sockfd, &echoed_len, 4, MSG_WAITALL) != 4) {
    perror("Header receive failed");
    close(sockfd);
    return 1;
  }

  echoed_len = ntohl(echoed_len); // Convert to host byte order

  // Receive message body
  int bytes_received = recv(sockfd, buffer, echoed_len, MSG_WAITALL);
  if (bytes_received != echoed_len) {
    perror("Body receive failed");
    close(sockfd);
    return 1;
  }

  // Print response
  printf("Server echoed: %.*s\n", echoed_len, buffer);
  printf("Echoed length: %d\n", echoed_len);

  close(sockfd);
  return 0;
}
