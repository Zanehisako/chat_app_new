#ifndef RUNNER_WINDOWS_PUSH_CHANNEL_H_
#define RUNNER_WINDOWS_PUSH_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

void InitializeWindowsPush();
void ShutdownWindowsPush();

class WindowsPushChannel {
 public:
  explicit WindowsPushChannel(flutter::BinaryMessenger* messenger);
  ~WindowsPushChannel();

  void SendActivation(const std::string& payload);

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_WINDOWS_PUSH_CHANNEL_H_
