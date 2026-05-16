// Shim header for the CWhisper system-library target.
//
// whisper.cpp's own headers are installed by scripts/build-whisper.sh into
// vendor/whisper-install/include; Package.swift adds that directory to the
// C header search path (`-I`). This shim simply re-exports the public API.
#include "whisper.h"
