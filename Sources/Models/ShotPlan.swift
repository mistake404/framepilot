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
            id: "tech-unboxing",
            name: "Tech & Unboxing",
            subtitle: "5 planos dinâmicos para gadgets, tech e reviews",
            iconName: "laptopcomputer.and.iphone",
            shots: [
                ShotTemplate(
                    id: "tech-1",
                    title: "Caixa & Hook",
                    kind: .medium,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 0.8...1.6,
                    targetPitchRange: -15...5,
                    maxRollDegrees: 2.5,
                    movementHint: "Push-in firme",
                    directorTip: "Apresenta a embalagem antes de abrir para criar antecipação."
                ),
                ShotTemplate(
                    id: "tech-2",
                    title: "Corte de Selo",
                    kind: .detail,
                    preferredMode: .video,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.25...0.55,
                    targetPitchRange: -28...(-5),
                    maxRollDegrees: 3.5,
                    movementHint: "Deslize lateral macro",
                    directorTip: "2x para focar o rasgar do selo plástico ou abertura da tampa."
                ),
                ShotTemplate(
                    id: "tech-3",
                    title: "Reveal do Produto",
                    kind: .lowAngle,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 0.5...1.2,
                    targetPitchRange: 12...28,
                    maxRollDegrees: 2.5,
                    movementHint: "Tilt-up herói",
                    directorTip: "Tira o produto da caixa em contrapicado para parecer premium."
                ),
                ShotTemplate(
                    id: "tech-4",
                    title: "Ecrã / Acabamento",
                    kind: .closeUp,
                    preferredMode: .video,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.35...0.8,
                    targetPitchRange: -20...10,
                    maxRollDegrees: 3.0,
                    movementHint: "Aproximação suave",
                    directorTip: "Mostra o ecrã a ligar, o vidro ou as portas de ligação."
                ),
                ShotTemplate(
                    id: "tech-5",
                    title: "Órbita em Mão",
                    kind: .orbit,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 3.0,
                    targetDistanceRange: 0.6...1.4,
                    targetPitchRange: -10...12,
                    maxRollDegrees: 3.0,
                    movementHint: "Arco 45°",
                    directorTip: "Segura o gadget na mão e faz uma rotação para mostrar ergonomia."
                )
            ]
        ),
        ScenePack(
            id: "ootd-fashion",
            name: "Moda & Outfit / OOTD",
            subtitle: "4 planos de estilo com corte para Reels de moda",
            iconName: "tshirt.fill",
            shots: [
                ShotTemplate(
                    id: "ootd-1",
                    title: "Caminhada Total",
                    kind: .establishing,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 3.0,
                    targetDistanceRange: 2.2...4.5,
                    targetPitchRange: -4...6,
                    maxRollDegrees: 2.0,
                    movementHint: "Avanço frontal",
                    directorTip: "Caminha em direção à câmara mostrando o look completo da cabeça aos pés."
                ),
                ShotTemplate(
                    id: "ootd-2",
                    title: "Ténis & Calçado",
                    kind: .lowAngle,
                    preferredMode: .video,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.6...1.4,
                    targetPitchRange: 18...38,
                    maxRollDegrees: 3.0,
                    movementHint: "Câmara junto ao chão",
                    directorTip: "0.5x colado ao chão dá escala às sapatilhas e corte da calça."
                ),
                ShotTemplate(
                    id: "ootd-3",
                    title: "Acessórios & Textura",
                    kind: .detail,
                    preferredMode: .video,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.3...0.75,
                    targetPitchRange: -15...12,
                    maxRollDegrees: 3.5,
                    movementHint: "Travelling lateral",
                    directorTip: "Foca relógio, joias, botões, cinto ou textura do tecido."
                ),
                ShotTemplate(
                    id: "ootd-4",
                    title: "Pose Confiante",
                    kind: .medium,
                    preferredMode: .video,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 1.3...2.5,
                    targetPitchRange: -6...8,
                    maxRollDegrees: 2.5,
                    movementHint: "Micro-push in",
                    directorTip: "Enquadramento dos joelhos para cima com olhar firme na câmara."
                )
            ]
        ),
        ScenePack(
            id: "barber-hair",
            name: "Barbearia & Cabelo",
            subtitle: "4 planos para transformação, corte e styling",
            iconName: "comb.fill",
            shots: [
                ShotTemplate(
                    id: "barber-1",
                    title: "Antes no Espelho",
                    kind: .medium,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 1.2...2.4,
                    targetPitchRange: -6...6,
                    maxRollDegrees: 2.0,
                    movementHint: "Estático",
                    directorTip: "Capta o estado inicial do cabelo e barba antes da tesoura."
                ),
                ShotTemplate(
                    id: "barber-2",
                    title: "Ação de Tesoura",
                    kind: .detail,
                    preferredMode: .video,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 0.35...0.85,
                    targetPitchRange: -15...10,
                    maxRollDegrees: 3.5,
                    movementHint: "Acompanha o corte",
                    directorTip: "2x para focar o cabelo a cair e o movimento das mãos."
                ),
                ShotTemplate(
                    id: "barber-3",
                    title: "Fade / Degradé",
                    kind: .closeUp,
                    preferredMode: .video,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.45...1.0,
                    targetPitchRange: -10...12,
                    maxRollDegrees: 2.5,
                    movementHint: "Deslize lateral na nuca",
                    directorTip: "Desliza em torno da têmpora/nuca para exibir a precisão do degradé."
                ),
                ShotTemplate(
                    id: "barber-4",
                    title: "Reveal do Final",
                    kind: .orbit,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 3.0,
                    targetDistanceRange: 0.9...1.8,
                    targetPitchRange: -5...12,
                    maxRollDegrees: 2.5,
                    movementHint: "Órbita 45°",
                    directorTip: "O cliente sacode a toalha e olha sorridente para o espelho."
                )
            ]
        ),
        ScenePack(
            id: "day-in-life",
            name: "Rotina / Day in the Life",
            subtitle: "5 planos com ritmo narrativo para vlogs de rotina",
            iconName: "sun.haze.fill",
            shots: [
                ShotTemplate(
                    id: "day-1",
                    title: "Despertar / Manhã",
                    kind: .medium,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 1.5...3.0,
                    targetPitchRange: -8...8,
                    maxRollDegrees: 2.0,
                    movementHint: "Push-in lento",
                    directorTip: "Câmara pousada a apanhar o primeiro momento do dia."
                ),
                ShotTemplate(
                    id: "day-2",
                    title: "Café / Pequeno-Almoço",
                    kind: .detail,
                    preferredMode: .video,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.3...0.7,
                    targetPitchRange: -25...(-5),
                    maxRollDegrees: 3.0,
                    movementHint: "Estático",
                    directorTip: "Café a pingar, chávena a encher ou vapor a subir."
                ),
                ShotTemplate(
                    id: "day-3",
                    title: "Saída de Casa",
                    kind: .reveal,
                    preferredMode: .video,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 1.4...3.2,
                    targetPitchRange: -6...6,
                    maxRollDegrees: 2.5,
                    movementHint: "Travelling da porta para a rua",
                    directorTip: "0.5x cria grande sensação de movimento ao passar a porta."
                ),
                ShotTemplate(
                    id: "day-4",
                    title: "Trabalho / Foco",
                    kind: .medium,
                    preferredMode: .video,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 2.5,
                    targetDistanceRange: 1.0...2.2,
                    targetPitchRange: -12...5,
                    maxRollDegrees: 2.5,
                    movementHint: "Avanço para a secretária",
                    directorTip: "Teclado, ecrã ou caderno com as mãos em movimento produtivo."
                ),
                ShotTemplate(
                    id: "day-5",
                    title: "Fim do Dia",
                    kind: .establishing,
                    preferredMode: .video,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 3.0,
                    targetDistanceRange: 2.0...5.0,
                    targetPitchRange: -6...10,
                    maxRollDegrees: 2.0,
                    movementHint: "Panorâmica relaxada",
                    directorTip: "Pôr do sol, fechar do portátil ou relaxar no sofá."
                )
            ]
        ),
        ScenePack(
            id: "luxury-tour",
            name: "Mansão & Luxury Tour",
            subtitle: "5 planos cinematográficos para propriedades de luxo",
            iconName: "building.2.crop.circle.fill",
            shots: [
                ShotTemplate(
                    id: "lux-1",
                    title: "Fachada Imponente",
                    kind: .lowAngle,
                    preferredMode: .video,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 3.5,
                    targetDistanceRange: 3.0...8.0,
                    targetPitchRange: 10...26,
                    maxRollDegrees: 1.5,
                    movementHint: "Travelling lento",
                    directorTip: "0.5x com horizonte rigoroso a 0° para a propriedade parecer grandiosa."
                ),
                ShotTemplate(
                    id: "lux-2",
                    title: "Entrada Principal",
                    kind: .reveal,
                    preferredMode: .video,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 3.0,
                    targetDistanceRange: 1.8...4.5,
                    targetPitchRange: -4...4,
                    maxRollDegrees: 1.5,
                    movementHint: "Deslize da porta para o hall",
                    directorTip: "Transição de luz exterior para os acabamentos do hall."
                ),
                ShotTemplate(
                    id: "lux-3",
                    title: "Sala Pé-Direito Duplo",
                    kind: .establishing,
                    preferredMode: .video,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 3.0,
                    targetDistanceRange: 2.5...6.0,
                    targetPitchRange: -2...12,
                    maxRollDegrees: 1.5,
                    movementHint: "Push-in contínuo",
                    directorTip: "Avança lentamente mostrando o teto alto e a luminosidade."
                ),
                ShotTemplate(
                    id: "lux-4",
                    title: "Cozinha / Mármore",
                    kind: .detail,
                    preferredMode: .video,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 2.0,
                    targetDistanceRange: 0.4...1.2,
                    targetPitchRange: -15...8,
                    maxRollDegrees: 2.5,
                    movementHint: "Deslize pela bancada",
                    directorTip: "2x destaca veios de pedra, torneiras douradas ou ilha central."
                ),
                ShotTemplate(
                    id: "lux-5",
                    title: "Piscina / Vista Exterior",
                    kind: .orbit,
                    preferredMode: .video,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 3.5,
                    targetDistanceRange: 2.5...6.5,
                    targetPitchRange: -8...10,
                    maxRollDegrees: 2.0,
                    movementHint: "Arco suave junto à água",
                    directorTip: "Termina com o reflexo do céu na piscina e o exterior da casa."
                )
            ]
        ),
        ScenePack(
            id: "photo-carousel-ig",
            name: "Carrossel Instagram 4:5 (Foto)",
            subtitle: "5 fotos 48MP com ritmo editorial para feed de alto impacto",
            iconName: "photo.stack.fill",
            shots: [
                ShotTemplate(
                    id: "igc-1",
                    title: "Capa Editorial Hero",
                    kind: .medium,
                    preferredMode: .photo,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 1.5...3.2,
                    targetPitchRange: -4...10,
                    maxRollDegrees: 1.5,
                    movementHint: "Estático firme",
                    directorTip: "Usa máscara 4:5 e 2x para comprimir o fundo na foto de capa."
                ),
                ShotTemplate(
                    id: "igc-2",
                    title: "Ambiente & Contexto",
                    kind: .establishing,
                    preferredMode: .photo,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 2.5...5.5,
                    targetPitchRange: -5...8,
                    maxRollDegrees: 1.5,
                    movementHint: "Estático nivelado",
                    directorTip: "Mostra o cenário completo para dar respiro visual ao slide 2."
                ),
                ShotTemplate(
                    id: "igc-3",
                    title: "Retrato Telefoto",
                    kind: .closeUp,
                    preferredMode: .photo,
                    recommendedLens: 5.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 2.0...4.5,
                    targetPitchRange: -4...6,
                    maxRollDegrees: 2.0,
                    movementHint: "Mão firme / 5x",
                    directorTip: "5x cria bokeh ótico real sem precisar de modo Retrato artificial."
                ),
                ShotTemplate(
                    id: "igc-4",
                    title: "Detalhe & Textura",
                    kind: .detail,
                    preferredMode: .photo,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 0.35...0.85,
                    targetPitchRange: -25...5,
                    maxRollDegrees: 3.0,
                    movementHint: "Foco por toque",
                    directorTip: "Relógio, café, tecido ou acessório para quebrar o ritmo do carrossel."
                ),
                ShotTemplate(
                    id: "igc-5",
                    title: "Fecho / Perspetiva",
                    kind: .lowAngle,
                    preferredMode: .photo,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 1.4...3.5,
                    targetPitchRange: 12...28,
                    maxRollDegrees: 2.0,
                    movementHint: "Contrapicado limpo",
                    directorTip: "Fecha o carrossel com uma foto marcante olhando ligeiramente para cima."
                )
            ]
        ),
        ScenePack(
            id: "photo-streetwear-editorial",
            name: "Editorial Moda & Streetwear (Foto)",
            subtitle: "5 fotos 48MP de look, compressão 5x e detalhes de estilo",
            iconName: "figure.stand",
            shots: [
                ShotTemplate(
                    id: "stw-1",
                    title: "Look Completo Contrapicado",
                    kind: .lowAngle,
                    preferredMode: .photo,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 2.0...3.8,
                    targetPitchRange: 8...20,
                    maxRollDegrees: 1.5,
                    movementHint: "Câmara à altura da cintura",
                    directorTip: "Baixa o iPhone à cintura e inclina ligeiramente para cima para alongar a silhueta."
                ),
                ShotTemplate(
                    id: "stw-2",
                    title: "Compressão Urbana 5x",
                    kind: .medium,
                    preferredMode: .photo,
                    recommendedLens: 5.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 3.0...6.0,
                    targetPitchRange: -3...8,
                    maxRollDegrees: 1.5,
                    movementHint: "Estático com cotovelos juntos",
                    directorTip: "Afasta-te com 5x para trazer edifícios e luzes do fundo para perto."
                ),
                ShotTemplate(
                    id: "stw-3",
                    title: "Ténis & Chão 0.5x",
                    kind: .lowAngle,
                    preferredMode: .photo,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 0.45...1.1,
                    targetPitchRange: 15...35,
                    maxRollDegrees: 2.5,
                    movementHint: "Rente ao chão",
                    directorTip: "0.5x perto do calçado cria perspetiva dramática de revista."
                ),
                ShotTemplate(
                    id: "stw-4",
                    title: "Retrato Olhar Lateral",
                    kind: .closeUp,
                    preferredMode: .photo,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 0.9...1.8,
                    targetPitchRange: -4...6,
                    maxRollDegrees: 2.0,
                    movementHint: "Toca nos olhos para focar",
                    directorTip: "Procura luz lateral de janela ou sombra aberta para pele natural."
                ),
                ShotTemplate(
                    id: "stw-5",
                    title: "A Caminhar Natural",
                    kind: .establishing,
                    preferredMode: .photo,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 2.5...4.5,
                    targetPitchRange: -3...6,
                    maxRollDegrees: 1.5,
                    movementHint: "Dispara no meio do passo",
                    directorTip: "Pede para caminhar devagar e dispara quando o pé da frente pousar."
                )
            ]
        ),
        ScenePack(
            id: "photo-cars-pro",
            name: "Fotografia Automóvel Pro (Foto)",
            subtitle: "5 fotos 48MP dignas de catálogo automóvel",
            iconName: "car.side.fill",
            shots: [
                ShotTemplate(
                    id: "car-p1",
                    title: "3/4 Frontal Imponente",
                    kind: .lowAngle,
                    preferredMode: .photo,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 3.0...6.0,
                    targetPitchRange: 4...16,
                    maxRollDegrees: 1.5,
                    movementHint: "Agachado à altura do farol",
                    directorTip: "2x elimina distorção do para-choques; vira as rodas ligeiramente para a câmara."
                ),
                ShotTemplate(
                    id: "car-p2",
                    title: "Farol & Grelha 5x",
                    kind: .detail,
                    preferredMode: .photo,
                    recommendedLens: 5.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 1.2...2.8,
                    targetPitchRange: -8...8,
                    maxRollDegrees: 2.0,
                    movementHint: "Estático / baixa EV -0.3",
                    directorTip: "5x com -0.3 EV faz os LEDs do farol e os reflexos brilharem."
                ),
                ShotTemplate(
                    id: "car-p3",
                    title: "Perfil Lateral Perfeito",
                    kind: .establishing,
                    preferredMode: .photo,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 4.0...7.5,
                    targetPitchRange: -2...4,
                    maxRollDegrees: 1.0,
                    movementHint: "Horizonte rigoroso 0°",
                    directorTip: "Centra perfeitamente na lateral com o horizonte travado a 0°."
                ),
                ShotTemplate(
                    id: "car-p4",
                    title: "Interior & Cockpit 0.5x",
                    kind: .medium,
                    preferredMode: .photo,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 0.6...1.4,
                    targetPitchRange: -15...5,
                    maxRollDegrees: 2.0,
                    movementHint: "Desde o banco traseiro",
                    directorTip: "0.5x captura o volante, ecrãs e consola central numa só imagem."
                ),
                ShotTemplate(
                    id: "car-p5",
                    title: "Traseira & Difusor",
                    kind: .lowAngle,
                    preferredMode: .photo,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 2.0...4.2,
                    targetPitchRange: 8...20,
                    maxRollDegrees: 1.5,
                    movementHint: "Baixo atrás das ponteiras",
                    directorTip: "Liga os mínimos traseiros para destacar a assinatura luminosa."
                )
            ]
        ),
        ScenePack(
            id: "photo-food-flatlay",
            name: "Gastronomia & Flat-Lay (Foto)",
            subtitle: "4 fotos 48MP com picado 90° e detalhes apetitosos",
            iconName: "fork.knife.circle.fill",
            shots: [
                ShotTemplate(
                    id: "food-p1",
                    title: "Flat-Lay 90° Perfeito",
                    kind: .highAngle,
                    preferredMode: .photo,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 0.55...1.1,
                    targetPitchRange: -90...(-72),
                    maxRollDegrees: 5.0,
                    movementHint: "Paralelo à mesa",
                    directorTip: "Usa a régua lateral até ficar verde no fundo (-85°) sem fazer sombra no prato."
                ),
                ShotTemplate(
                    id: "food-p2",
                    title: "Ângulo 45° Editorial",
                    kind: .medium,
                    preferredMode: .photo,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 0.5...1.0,
                    targetPitchRange: -52...(-35),
                    maxRollDegrees: 2.5,
                    movementHint: "Luz de janela lateral",
                    directorTip: "2x a 45° é o ângulo clássico que mostra altura do prato e ingredientes."
                ),
                ShotTemplate(
                    id: "food-p3",
                    title: "Macro Textura & Brilho",
                    kind: .detail,
                    preferredMode: .photo,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 0.25...0.55,
                    targetPitchRange: -25...0,
                    maxRollDegrees: 3.0,
                    movementHint: "Toca na zona mais suculenta",
                    directorTip: "Enche o ecrã com o corte, molho ou vapor do prato."
                ),
                ShotTemplate(
                    id: "food-p4",
                    title: "Mesa & Ambiente",
                    kind: .establishing,
                    preferredMode: .photo,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 1.1...2.2,
                    targetPitchRange: -30...(-10),
                    maxRollDegrees: 2.0,
                    movementHint: "Inclui bebida e mãos",
                    directorTip: "Mostra copos, talheres e a atmosfera do restaurante."
                )
            ]
        ),
        ScenePack(
            id: "photo-architecture-travel",
            name: "Arquitetura & Viagem (Foto)",
            subtitle: "5 fotos 48MP com simetria, grande angular e telefoto 5x",
            iconName: "building.columns.fill",
            shots: [
                ShotTemplate(
                    id: "arch-1",
                    title: "Simetria Grande Angular",
                    kind: .establishing,
                    preferredMode: .photo,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 3.0...8.0,
                    targetPitchRange: -3...6,
                    maxRollDegrees: 1.0,
                    movementHint: "Horizonte exato a 0°",
                    directorTip: "Alinha as colunas ou corredores com a grelha dos terços."
                ),
                ShotTemplate(
                    id: "arch-2",
                    title: "Fachada Olhar ao Céu",
                    kind: .lowAngle,
                    preferredMode: .photo,
                    recommendedLens: 0.5,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 2.5...7.0,
                    targetPitchRange: 30...65,
                    maxRollDegrees: 3.0,
                    movementHint: "Contrapicado acentuado",
                    directorTip: "Usa a régua lateral para apontar para cima e criar linhas convergentes."
                ),
                ShotTemplate(
                    id: "arch-3",
                    title: "Compressão Urbana 5x",
                    kind: .medium,
                    preferredMode: .photo,
                    recommendedLens: 5.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 4.0...10.0,
                    targetPitchRange: -4...10,
                    maxRollDegrees: 1.5,
                    movementHint: "Mão firme / 5x",
                    directorTip: "Isola janelas, telhados ou monumentos ao longe com 5x."
                ),
                ShotTemplate(
                    id: "arch-4",
                    title: "Luz, Sombra & Detalhe",
                    kind: .detail,
                    preferredMode: .photo,
                    recommendedLens: 2.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 1.0...3.5,
                    targetPitchRange: -12...15,
                    maxRollDegrees: 2.0,
                    movementHint: "Baixa EV -0.5 nas sombras",
                    directorTip: "Usa o EV negativo na gaveta PRO para sombras dramáticas e texturas ricas."
                ),
                ShotTemplate(
                    id: "arch-5",
                    title: "Escala Humana",
                    kind: .establishing,
                    preferredMode: .photo,
                    recommendedLens: 1.0,
                    targetDurationSeconds: 0,
                    targetDistanceRange: 3.0...7.0,
                    targetPitchRange: -4...8,
                    maxRollDegrees: 1.5,
                    movementHint: "Pessoa num terço lateral",
                    directorTip: "Coloca uma pessoa pequena no plano para dar noção real de grandiosidade."
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
