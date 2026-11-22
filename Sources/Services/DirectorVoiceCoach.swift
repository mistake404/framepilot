import AVFoundation
import Foundation
import QuartzCore

/// Hands-free Portuguese voice director using offline AVSpeechSynthesizer.
/// Never speaks during video recording so it never contaminates recorded audio.
final class DirectorVoiceCoach {
    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpokenText: String = ""
    private var lastSpokenTime: CFTimeInterval = 0

    private lazy var voice: AVSpeechSynthesisVoice? = {
        AVSpeechSynthesisVoice(language: "pt-PT")
            ?? AVSpeechSynthesisVoice(language: "pt-BR")
    }()

    func stopImmediately() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    func speakCountdown(_ number: Int) {
        stopImmediately()
        enqueue("\(number)", rate: 0.54)
    }

    func speakVerdict(_ verdict: TakeVerdict) {
        stopImmediately()
        let line = verdict.isApproved ? "Boa tomada!" : "Dá para melhorar. \(verdict.detail)"
        lastSpokenText = line
        lastSpokenTime = CACurrentMediaTime()
        enqueue(line, rate: 0.51)
    }

    func speakAdviceIfAppropriate(_ advice: CoachingAdvice, isRecording: Bool) {
        guard !isRecording else {
            stopImmediately()
            return
        }
        let text = shortSpokenCue(for: advice)
        guard !text.isEmpty else { return }

        let now = CACurrentMediaTime()
        let isSame = (text == lastSpokenText)
        let cooldown: CFTimeInterval = isSame ? 5.5 : 2.6
        guard now - lastSpokenTime >= cooldown else { return }
        if synthesizer.isSpeaking { return }

        lastSpokenText = text
        lastSpokenTime = now
        enqueue(text, rate: 0.51)
    }

    private func shortSpokenCue(for advice: CoachingAdvice) -> String {
        let p = advice.primaryInstruction
        if advice.isLocked {
            return "Perfeito, dispara"
        }
        if p.hasPrefix("Afasta-te") { return "Afasta um pouco" }
        if p.hasPrefix("Aproxima-te") { return "Aproxima um pouco" }
        if p.hasPrefix("Inclina mais para cima") { return "Inclina para cima" }
        if p.hasPrefix("Aponta mais para baixo") { return "Aponta para baixo" }
        if p.hasPrefix("Nivela o horizonte") || p.hasPrefix("Horizonte inclinado") { return "Nivela o horizonte" }
        if p.hasPrefix("Dá mais ar") { return "Dá mais ar acima da cabeça" }
        if p.hasPrefix("Sobe o rosto") { return "Sobe o rosto" }
        if p.hasPrefix("Estabiliza a mão") { return "Mantém a mão firme" }
        return ""
    }

    private func enqueue(_ text: String, rate: Float) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        utterance.volume = 0.85
        synthesizer.speak(utterance)
    }
}
