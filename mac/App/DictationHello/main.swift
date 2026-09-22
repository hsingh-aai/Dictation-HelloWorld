import DictationEngine
import Foundation

// Headless self-test: feeds a WAV through the real streaming transcriber and prints both
// transcripts. Proves the wire contract on a machine where nothing has been granted yet.
//   DictationHello --selftest clip.wav    (key from ASSEMBLYAI_API_KEY, else the Keychain)
if let index = CommandLine.arguments.firstIndex(of: "--selftest") {
    let path = CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : ""
    exit(SelfTest.run(path: path))
}

DictationHelloApp.main()
