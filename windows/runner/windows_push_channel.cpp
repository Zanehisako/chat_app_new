#include "windows_push_channel.h"

#include <flutter/method_call.h>
#include <flutter/standard_method_codec.h>

#include <mutex>
#include <optional>
#include <thread>
#include <utility>

#ifdef CHAT_APP_ENABLE_WNS
#include <winrt/Microsoft.Windows.AppLifecycle.h>
#include <winrt/Microsoft.Windows.AppNotifications.h>
#include <winrt/Microsoft.Windows.PushNotifications.h>
#include <winrt/Windows.Foundation.h>
#endif

namespace {

constexpr char kChannelName[] = "chat_app/windows_push";

std::mutex g_activation_mutex;
WindowsPushChannel* g_channel = nullptr;
std::string g_pending_activation;

void DispatchActivation(std::string payload) {
  std::lock_guard<std::mutex> lock(g_activation_mutex);
  if (g_channel != nullptr) {
    // The Flutter channel buffers method calls until Dart installs its handler.
    // Keeping a second copy would route the same activation twice on startup.
    g_channel->SendActivation(payload);
    return;
  }
  g_pending_activation = std::move(payload);
}

std::string TakePendingActivation() {
  std::lock_guard<std::mutex> lock(g_activation_mutex);
  auto payload = std::move(g_pending_activation);
  g_pending_activation.clear();
  return payload;
}

#ifdef CHAT_APP_ENABLE_WNS
using winrt::Microsoft::Windows::AppLifecycle::AppInstance;
using winrt::Microsoft::Windows::AppLifecycle::ExtendedActivationKind;
using winrt::Microsoft::Windows::AppNotifications::AppNotificationActivatedEventArgs;
using winrt::Microsoft::Windows::AppNotifications::AppNotificationManager;
using winrt::Microsoft::Windows::PushNotifications::PushNotificationChannelStatus;
using winrt::Microsoft::Windows::PushNotifications::PushNotificationManager;
using winrt::Microsoft::Windows::PushNotifications::PushNotificationReceivedEventArgs;

std::once_flag g_registration_once;

void EnsureWnsRegistered() {
  std::call_once(g_registration_once, []() {
    if (!PushNotificationManager::IsSupported()) {
      return;
    }

    const auto push_manager = PushNotificationManager::Default();
    // Event handlers must be attached before Register().
    push_manager.PushReceived([](const auto&, const PushNotificationReceivedEventArgs& args) {
      const auto payload = args.Payload();
      DispatchActivation(std::string(payload.begin(), payload.end()));
    });
    push_manager.Register();

    const auto app_notifications = AppNotificationManager::Default();
    app_notifications.NotificationInvoked(
        [](const auto&, const AppNotificationActivatedEventArgs& args) {
          DispatchActivation(winrt::to_string(args.Argument()));
        });
    app_notifications.Register();
  });
}

void CaptureStartupActivation() {
  const auto activation = AppInstance::GetCurrent().GetActivatedEventArgs();
  if (activation.Kind() == ExtendedActivationKind::AppNotification) {
    const auto args = activation.Data().as<AppNotificationActivatedEventArgs>();
    DispatchActivation(winrt::to_string(args.Argument()));
  } else if (activation.Kind() == ExtendedActivationKind::Push) {
    const auto args = activation.Data().as<PushNotificationReceivedEventArgs>();
    const auto payload = args.Payload();
    DispatchActivation(std::string(payload.begin(), payload.end()));
  }
}
#endif

}  // namespace

void InitializeWindowsPush() {
#ifdef CHAT_APP_ENABLE_WNS
  try {
    winrt::init_apartment(winrt::apartment_type::single_threaded);
    EnsureWnsRegistered();
    CaptureStartupActivation();
  } catch (...) {
    // WNS must not prevent the Flutter runner from starting.
  }
#endif
}

void ShutdownWindowsPush() {
#ifdef CHAT_APP_ENABLE_WNS
  try {
    PushNotificationManager::Default().Unregister();
    AppNotificationManager::Default().Unregister();
  } catch (...) {
    // Shutdown should not block process termination.
  }
#endif
}

WindowsPushChannel::WindowsPushChannel(flutter::BinaryMessenger* messenger)
    : channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kChannelName,
          &flutter::StandardMethodCodec::GetInstance())) {
  channel_->Resize(1);
  {
    std::lock_guard<std::mutex> lock(g_activation_mutex);
    g_channel = this;
  }
  channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() == "getInitialActivation") {
          result->Success(flutter::EncodableValue(TakePendingActivation()));
          return;
        }
        if (call.method_name() != "requestChannelUri") {
          result->NotImplemented();
          return;
        }

        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Error("invalid_arguments", "Missing WNS remoteId.");
          return;
        }
        const auto remote_id_entry =
            arguments->find(flutter::EncodableValue("remoteId"));
        if (remote_id_entry == arguments->end()) {
          result->Error("invalid_arguments", "Missing WNS remoteId.");
          return;
        }
        const auto* remote_id =
            std::get_if<std::string>(&remote_id_entry->second);
        if (remote_id == nullptr || remote_id->empty()) {
          result->Error("invalid_arguments", "Invalid WNS remoteId.");
          return;
        }

#ifdef CHAT_APP_ENABLE_WNS
        const auto remote_id_copy = *remote_id;
        std::thread([remote_id_copy, result = std::move(result)]() mutable {
          try {
            winrt::init_apartment(winrt::apartment_type::multi_threaded);
            if (!PushNotificationManager::IsSupported()) {
              result->Error("unsupported", "WNS is not supported on this device.");
              return;
            }
            EnsureWnsRegistered();
            const auto operation = PushNotificationManager::Default()
                                       .CreateChannelAsync(
                                           winrt::guid(winrt::to_hstring(remote_id_copy)));
            const auto channel_result = operation.get();
            if (channel_result.Status() !=
                PushNotificationChannelStatus::CompletedSuccess) {
              result->Error("channel_request_failed",
                            "Windows could not create a WNS channel URI.");
              return;
            }
            result->Success(flutter::EncodableValue(winrt::to_string(
                channel_result.Channel().Uri().ToString())));
          } catch (const std::exception& error) {
            result->Error("channel_request_failed", error.what());
          }
        }).detach();
#else
        result->Error(
            "not_configured",
            "Build with CHAT_APP_ENABLE_WNS and the Windows App SDK to use WNS.");
#endif
      });
}

WindowsPushChannel::~WindowsPushChannel() {
  std::lock_guard<std::mutex> lock(g_activation_mutex);
  if (g_channel == this) {
    g_channel = nullptr;
  }
}

void WindowsPushChannel::SendActivation(const std::string& payload) {
  channel_->InvokeMethod(
      "pushActivated",
      std::make_unique<flutter::EncodableValue>(payload));
}
