import Foundation

enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case photo = "Foto"
    case video = "Vídeo"

    var id: String { rawValue }
}

enum ShotKind: String, CaseIterable, Identifiable, Codable {
    case establishing = "Plano Geral"
    case medium = "Plano Médio"
    case closeUp = "Grande Plano"
    case detail = "Detalhe"
    case lowAngle = "Contrapicado"
    case highAngle = "Picado"
    case reveal = "Reveal"
    case orbit = "Órbita"

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .establishing: return "pano"
        case .medium: return "person.crop.rectangle"
        case .closeUp: return "viewfinder.circle"
        case .detail: return "sparkle.magnifyingglass"
        case .lowAngle: return "arrow.up.forward.circle"
        case .highAngle: return "arrow.down.forward.circle"
        case .reveal: return "rectangle.expand.vertical"
        case .orbit: return "arrow.triangle.2.circlepath.camera"
        }
    }

    var defaultDistanceRange: ClosedRange<Double> {
        switch self {
        case .establishing: return 2.0...4.5
        case .medium: return 1.2...2.4
        case .closeUp: return 0.7...1.3
        case .detail: return 0.3...0.8
        case .lowAngle: return 1.0...2.8
        case .highAngle: return 0.6...1.5
        case .reveal: return 1.4...3.2
        case .orbit: return 0.8...1.8
        }
    }

    var defaultPitchRange: ClosedRange<Double> {
        switch self {
        case .lowAngle: return 12...32
        case .highAngle: return -80...(-35)
        case .detail: return -25...12
        default: return -10...10
        }
    }

    var defaultMovementHint: String {
        switch self {
        case .establishing: return "Panorâmica lenta"
        case .medium: return "Acompanhamento suave"
        case .closeUp: return "Estático / micro-push"
        case .detail: return "Deslize lateral curto"
        case .lowAngle: return "Tilt-up suave"
        case .highAngle: return "Estático superior"
        case .reveal: return "Travelling lateral"
        case .orbit: return "Órbita 45° à volta"
        }
    }
}

struct ShotTemplate: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let kind: ShotKind
    let preferredMode: CaptureMode
    let recommendedLens: Double                  // 0.5, 1.0, 2.0, 5.0
    let targetDurationSeconds: Double            // duração alvo para ritmo viral (ex.: 2.5s)
    let targetDistanceRange: ClosedRange<Double> // metros (via LiDAR)
    let targetPitchRange: ClosedRange<Double>    // graus (+ = cima, - = baixo)
    let maxRollDegrees: Double                   // tolerância do horizonte
    let movementHint: String
    let directorTip: String

    var distanceLabel: String {
        String(format: "%.1f–%.1fm", targetDistanceRange.lowerBound, targetDistanceRange.upperBound)
    }

    var pitchLabel: String {
        let low = Int(targetPitchRange.lowerBound.rounded())
        let high = Int(targetPitchRange.upperBound.rounded())
        return "\(low)° a \(high)°"
    }

    var lensLabel: String {
        recommendedLens == 0.5 ? "0.5x" : "\(Int(recommendedLens))x"
    }

    var durationLabel: String {
        targetDurationSeconds.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(targetDurationSeconds))s"
            : String(format: "%.1fs", targetDurationSeconds)
    }
}

struct ScenePack: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let subtitle: String
    let iconName: String
    let shots: [ShotTemplate]
    var isCustom: Bool = false

    static let presets: [ScenePack] = [
        ScenePack(
            id: "ugc-product",
            name: "Reel Produto / UGC",
            subtitle: "5 planos com ritmo para apresentação de produto",
            iconName: "shippingbox.fill",
            shots: [
                ShotTemplate(
                    id: "ugc-1",
                    title: "Contexto",
                    kind: .establishing,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 1.4...2.8,
                    targetPitchRange: -12...8,
                    maxRollDegrees: 3.0,
                    movementHint: "Push-in lento",
                    directorTip: "Mostra o produto inserido no ambiente antes de te aproximares."
                ),
                ShotTemplate(
                    id: "ugc-2",
                    title: "Herói Baixo",
                    kind: .lowAngle,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.6...1.3,
                    targetPitchRange: 10...28,
                    maxRollDegrees: 3.0,
                    movementHint: "Micro-tilt para cima",
                    directorTip: "Baixa o iPhone ao nível da mesa e inclina ligeiramente para cima."
                ),
                ShotTemplate(
                    id: "ugc-3",
                    title: "Detalhe Textura",
                    kind: .detail,
                    preferredMode: .video,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.25...0.65,
                    targetPitchRange: -25...10,
                    maxRollDegrees: 4.5,
                    movementHint: "Deslize lateral suave",
                    directorTip: "Usa 2x para comprimir o fundo e destacar rótulo ou material."
                ),
                ShotTemplate(
                    id: "ugc-4",
                    title: "Vista Superior",
                    kind: .highAngle,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.5...1.1,
                    targetPitchRange: -85...(-45),
                    maxRollDegrees: 5.0,
                    movementHint: "Flat-lay estável",
                    directorTip: "Aponta de cima para baixo para enquadrar o produto com elementos de apoio."
                ),
                ShotTemplate(
                    id: "ugc-5",
                    title: "Órbita Final",
                    kind: .orbit,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 3.0,
                    targetDistanceRange: 0.7...1.5,
                    targetPitchRange: -8...12,
                    maxRollDegrees: 3.0,
                    movementHint: "Roda 45° à volta",
                    directorTip: "Mantém o produto no centro da mira enquanto deslizas em arco."
                )
            ]
        ),
        ScenePack(
            id: "travel-street",
            name: "Viagem & Rua",
            subtitle: "Narrativa visual completa para Reels de viagem",
            iconName: "airplane.departure",
            shots: [
                ShotTemplate(
                    id: "trv-1",
                    title: "Situar o Local",
                    kind: .establishing,
                    preferredMode: .video,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 3.0,
                    targetDistanceRange: 2.5...5.0,
                    targetPitchRange: -8...12,
                    maxRollDegrees: 2.5,
                    movementHint: "Panorâmica lenta",
                    directorTip: "Usa 0.5x para abrir a arquitetura/paisagem com horizonte nivelado."
                ),
                ShotTemplate(
                    id: "trv-2",
                    title: "Contrapicado Urbano",
                    kind: .lowAngle,
                    preferredMode: .video,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 1.2...3.5,
                    targetPitchRange: 18...42,
                    maxRollDegrees: 3.5,
                    movementHint: "Avanço junto ao chão",
                    directorTip: "0.5x + contrapicado dá escala dramática a edifícios e ruas."
                ),
                ShotTemplate(
                    id: "trv-3",
                    title: "Plano Médio",
                    kind: .medium,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 1.2...2.4,
                    targetPitchRange: -8...8,
                    maxRollDegrees: 3.0,
                    movementHint: "Acompanhamento lateral",
                    directorTip: "Captura ação humana, movimento na rua ou expressão do momento."
                ),
                ShotTemplate(
                    id: "trv-4",
                    title: "Detalhe Local",
                    kind: .detail,
                    preferredMode: .video,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.35...0.9,
                    targetPitchRange: -20...15,
                    maxRollDegrees: 4.0,
                    movementHint: "Push-in curto",
                    directorTip: "Um café, azulejo, sinalética ou textura cria ritmo na edição."
                )
            ]
        ),
        ScenePack(
            id: "food-cafe",
            name: "Restaurante / Café",
            subtitle: "4 planos apetitosos para gastronomia e cafés",
            iconName: "fork.knife",
            shots: [
                ShotTemplate(
                    id: "food-1",
                    title: "Ambiente Espaço",
                    kind: .establishing,
                    preferredMode: .video,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 1.8...4.0,
                    targetPitchRange: -8...8,
                    maxRollDegrees: 2.5,
                    movementHint: "Reveal lento",
                    directorTip: "Mostra o ambiente acolhedor do restaurante ou esplanada."
                ),
                ShotTemplate(
                    id: "food-2",
                    title: "Ação / Servir",
                    kind: .medium,
                    preferredMode: .video,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 3.0,
                    targetDistanceRange: 0.6...1.3,
                    targetPitchRange: -22...(-5),
                    maxRollDegrees: 3.0,
                    movementHint: "Estático focado na ação",
                    directorTip: "Capta molho a cair, café a verter ou prato a pousar na mesa."
                ),
                ShotTemplate(
                    id: "food-3",
                    title: "Flat-Lay Mesa",
                    kind: .highAngle,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.55...1.1,
                    targetPitchRange: -85...(-55),
                    maxRollDegrees: 4.0,
                    movementHint: "Pull-back suave",
                    directorTip: "Vista aérea dos pratos, copos e talheres alinhados."
                ),
                ShotTemplate(
                    id: "food-4",
                    title: "Detalhe Textura",
                    kind: .detail,
                    preferredMode: .video,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.25...0.6,
                    targetPitchRange: -20...5,
                    maxRollDegrees: 4.0,
                    movementHint: "Micro-deslize lateral",
                    directorTip: "Aproxima para mostrar vapor, brilho e textura do prato."
                )
            ]
        ),
        ScenePack(
            id: "real-estate",
            name: "Imobiliária / Interiores",
            subtitle: "4 planos amplos e nivelados para casas e espaços",
            iconName: "house.fill",
            shots: [
                ShotTemplate(
                    id: "re-1",
                    title: "Reveal Entrada",
                    kind: .reveal,
                    preferredMode: .video,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 3.5,
                    targetDistanceRange: 2.0...5.0,
                    targetPitchRange: -5...5,
                    maxRollDegrees: 2.0,
                    movementHint: "Deslize a partir da porta",
                    directorTip: "Horizonte cravado a 0° para manter paredes perfeitamente verticais."
                ),
                ShotTemplate(
                    id: "re-2",
                    title: "Amplitude Divisão",
                    kind: .establishing,
                    preferredMode: .video,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 3.0,
                    targetDistanceRange: 2.2...5.0,
                    targetPitchRange: -4...6,
                    maxRollDegrees: 2.0,
                    movementHint: "Push-in lento",
                    directorTip: "Câmara à altura do peito dá a sensação real de espaço."
                ),
                ShotTemplate(
                    id: "re-3",
                    title: "Detalhe Acabamento",
                    kind: .detail,
                    preferredMode: .video,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.5...1.2,
                    targetPitchRange: -12...10,
                    maxRollDegrees: 2.5,
                    movementHint: "Travelling lateral curto",
                    directorTip: "Destaca mármore, madeira, iluminação ou decoração."
                ),
                ShotTemplate(
                    id: "re-4",
                    title: "Luz & Vista",
                    kind: .medium,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 1.5...3.5,
                    targetPitchRange: -5...8,
                    maxRollDegrees: 2.0,
                    movementHint: "Avanço para a janela",
                    directorTip: "Baixa ligeiramente o EV (-0.5) para não estourar a luz exterior."
                )
            ]
        ),
        ScenePack(
            id: "fitness-training",
            name: "Fitness / Treino",
            subtitle: "4 planos dinâmicos para ginásio e desporto",
            iconName: "figure.strengthtraining.traditional",
            shots: [
                ShotTemplate(
                    id: "fit-1",
                    title: "Entrada Herói",
                    kind: .lowAngle,
                    preferredMode: .video,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 1.4...3.0,
                    targetPitchRange: 14...32,
                    maxRollDegrees: 3.0,
                    movementHint: "Contrapicado firme",
                    directorTip: "Ângulo baixo dá impacto e presença logo nos primeiros segundos."
                ),
                ShotTemplate(
                    id: "fit-2",
                    title: "Execução Média",
                    kind: .medium,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 3.0,
                    targetDistanceRange: 1.5...2.8,
                    targetPitchRange: -6...10,
                    maxRollDegrees: 3.0,
                    movementHint: "Acompanha o movimento",
                    directorTip: "Enquadra a técnica completa sem cortar mãos nem pés."
                ),
                ShotTemplate(
                    id: "fit-3",
                    title: "Detalhe Esforço",
                    kind: .detail,
                    preferredMode: .video,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.5...1.2,
                    targetPitchRange: -10...15,
                    maxRollDegrees: 3.5,
                    movementHint: "Push-in rápido",
                    directorTip: "Mãos na barra, expressão ou equipamento dão energia ao corte."
                ),
                ShotTemplate(
                    id: "fit-4",
                    title: "Órbita Final",
                    kind: .orbit,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 1.2...2.4,
                    targetPitchRange: 6...20,
                    maxRollDegrees: 3.0,
                    movementHint: "Arco lateral fluido",
                    directorTip: "Roda à volta do atleta mantendo o tronco no centro."
                )
            ]
        ),
        ScenePack(
            id: "talking-head",
            name: "Talking Head / Vlog",
            subtitle: "3 planos para falar para a câmara + B-roll",
            iconName: "mic.fill",
            shots: [
                ShotTemplate(
                    id: "vlog-1",
                    title: "Hook Principal",
                    kind: .closeUp,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 5.0,
                    targetDistanceRange: 0.8...1.4,
                    targetPitchRange: -4...6,
                    maxRollDegrees: 2.0,
                    movementHint: "Estático à altura dos olhos",
                    directorTip: "Olhos no terço superior e espaço livre abaixo para legendas."
                ),
                ShotTemplate(
                    id: "vlog-2",
                    title: "B-Roll Contexto",
                    kind: .establishing,
                    preferredMode: .video,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 1.8...3.8,
                    targetPitchRange: -6...8,
                    maxRollDegrees: 2.5,
                    movementHint: "Panorâmica lenta",
                    directorTip: "Plano de corte do ambiente para quebrar a monotonia da fala."
                ),
                ShotTemplate(
                    id: "vlog-3",
                    title: "B-Roll Detalhe",
                    kind: .detail,
                    preferredMode: .video,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.35...0.9,
                    targetPitchRange: -18...10,
                    maxRollDegrees: 3.5,
                    movementHint: "Deslize suave",
                    directorTip: "Mostra o objeto, ecrã ou ação de que estás a falar."
                )
            ]
        ),
        ScenePack(
            id: "editorial-portrait",
            name: "Retrato Editorial",
            subtitle: "4 ângulos com lentes que valorizam o rosto",
            iconName: "person.fill.viewfinder",
            shots: [
                ShotTemplate(
                    id: "prt-1",
                    title: "Retrato Ambiental",
                    kind: .establishing,
                    preferredMode: .photo,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 2.0...3.8,
                    targetPitchRange: -6...6,
                    maxRollDegrees: 2.5,
                    movementHint: "Estático",
                    directorTip: "Mostra o sujeito de corpo inteiro integrado no cenário."
                ),
                ShotTemplate(
                    id: "prt-2",
                    title: "Plano Americano",
                    kind: .medium,
                    preferredMode: .photo,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 1.4...2.4,
                    targetPitchRange: -5...8,
                    maxRollDegrees: 2.5,
                    movementHint: "Estático",
                    directorTip: "2x com a câmara à altura do peito dá proporções de cinema."
                ),
                ShotTemplate(
                    id: "prt-3",
                    title: "Grande Plano",
                    kind: .closeUp,
                    preferredMode: .photo,
                    recommendedLens: 5.0,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 1.0...2.0,
                    targetPitchRange: -6...6,
                    maxRollDegrees: 2.5,
                    movementHint: "Estático",
                    directorTip: "5x comprime o fundo e cria desfoque natural sem distorcer o rosto."
                ),
                ShotTemplate(
                    id: "prt-4",
                    title: "Ângulo Herói",
                    kind: .lowAngle,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 1.0...2.0,
                    targetPitchRange: 12...26,
                    maxRollDegrees: 3.0,
                    movementHint: "Tilt-up lento",
                    directorTip: "Baixa o telemóvel para dar imponência e silhueta limpa."
                )
            ]
        ),
        ScenePack(
            id: "automotive",
            name: "Carro / Moto",
            subtitle: "Ângulos cinematográficos de baixa altura e detalhes",
            iconName: "car.fill",
            shots: [
                ShotTemplate(
                    id: "car-1",
                    title: "3/4 Baixo",
                    kind: .lowAngle,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 2.0...4.2,
                    targetPitchRange: 6...22,
                    maxRollDegrees: 2.5,
                    movementHint: "Agachado junto aos faróis",
                    directorTip: "Baixa à altura do farol para o veículo parecer mais largo e agressivo."
                ),
                ShotTemplate(
                    id: "car-2",
                    title: "Reveal Lateral",
                    kind: .reveal,
                    preferredMode: .video,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 3.0,
                    targetDistanceRange: 1.4...3.0,
                    targetPitchRange: -4...10,
                    maxRollDegrees: 2.5,
                    movementHint: "Travelling lateral suave",
                    directorTip: "0.5x percorre as linhas da carroçaria com grande sensação de velocidade."
                ),
                ShotTemplate(
                    id: "car-3",
                    title: "Detalhe Jante / Farol",
                    kind: .detail,
                    preferredMode: .video,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.4...1.0,
                    targetPitchRange: -15...15,
                    maxRollDegrees: 3.5,
                    movementHint: "Push-in curto",
                    directorTip: "Usa 2x para focar reflexos, pinça de travão, emblema ou ótica."
                )
            ]
        ),
        ScenePack(
            id: "free-mode",
            name: "Modo Livre",
            subtitle: "Qualidade Pro + LiDAR + deteção automática de plano",
            iconName: "camera.metering.matrix",
            shots: []
        )
    ]
}

enum CustomPackStore {
    private static let key = "com.framepilot.customScenePacks.v1"

    static func load() -> [ScenePack] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([ScenePack].self, from: data) else {
            return []
        }
        return decoded
    }

    static func save(_ packs: [ScenePack]) {
        if let data = try? JSONEncoder().encode(packs) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
