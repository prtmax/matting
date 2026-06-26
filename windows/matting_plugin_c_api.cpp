#include "include/matting/matting_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "matting_plugin.h"

void MattingPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  matting::MattingPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
