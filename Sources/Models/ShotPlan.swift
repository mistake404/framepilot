import Foundation

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo = "Foto"
    case video = "Vídeo"

    var id: String { rawValue }
}

enum ShotKind: String, CaseIterable, Identifiable {
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
}

struct ShotTemplate: Identifiable, Hashable {
    let id: String
    let title: String
    let kind: ShotKind
    let preferredMode: CaptureMode
    let targetDistanceRange: ClosedRange<Double> // metros (via LiDAR)
    let targetPitchRange: ClosedRange<Double>    // graus (+ = olhar para cima, - = olhar para baixo)
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
}

struct ScenePack: Identifiable, Hashable {
    let id: String
    let name: String
    let subtitle: String
    let iconName: String
    let shots: [ShotTemplate]

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
                    targetDistanceRange: 1.4...2.8,
                    targetPitchRange: -12...8,
                    maxRollDegrees: 3.0,
                    movementHint: "Push-in lento (3s)",
                    directorTip: "Mostra o produto inserido no ambiente antes de te aproximares."
                ),
                ShotTemplate(
                    id: "ugc-2",
                    title: "Herói Baixo",
                    kind: .lowAngle,
                    preferredMode: .photo,
                    targetDistanceRange: 0.6...1.3,
                    targetPitchRange: 10...28,
                    maxRollDegrees: 3.0,
                    movementHint: "Estático / micro-tilt",
                    directorTip: "Baixa o iPhone ao nível da mesa e inclina ligeiramente para cima para dar presença."
                ),
                ShotTemplate(
                    id: "ugc-3",
                    title: "Detalhe Textura",
                    kind: .detail,
                    preferredMode: .video,
                    targetDistanceRange: 0.25...0.55,
                    targetPitchRange: -25...10,
                    maxRollDegrees: 4.5,
                    movementHint: "Deslize lateral suave",
                    directorTip: "Aproxima bem para destacar rótulo, acabamento ou material."
                ),
                ShotTemplate(
                    id: "ugc-4",
                    title: "Vista Superior",
                    kind: .highAngle,
                    preferredMode: .photo,
                    targetDistanceRange: 0.5...1.1,
                    targetPitchRange: -85...(-45),
                    maxRollDegrees: 5.0,
                    movementHint: "Estático (flat-lay)",
                    directorTip: "Aponta de cima para baixo para enquadrar o produto com elementos de apoio."
                ),
                ShotTemplate(
                    id: "ugc-5",
                    title: "Órbita Final",
                    kind: .orbit,
                    preferredMode: .video,
                    targetDistanceRange: 0.7...1.5,
                    targetPitchRange: -8...12,
                    maxRollDegrees: 3.0,
                    movementHint: "Roda 45° à volta do sujeito",
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
                    targetDistanceRange: 2.5...5.0,
                    targetPitchRange: -8...12,
                    maxRollDegrees: 2.5,
                    movementHint: "Panorâmica lenta",
                    directorTip: "Abre a cena com arquitetura ou paisagem e horizonte bem nivelado."
                ),
                ShotTemplate(
                    id: "trv-2",
                    title: "Contrapicado Urbano",
                    kind: .lowAngle,
                    preferredMode: .photo,
                    targetDistanceRange: 1.2...3.5,
                    targetPitchRange: 18...42,
                    maxRollDegrees: 3.5,
                    movementHint: "Estático junto ao chão",
                    directorTip: "Dá escala a edifícios, arcos ou pessoas a caminhar."
                ),
                ShotTemplate(
                    id: "trv-3",
                    title: "Plano Médio",
                    kind: .medium,
                    preferredMode: .video,
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
                    preferredMode: .photo,
                    targetDistanceRange: 0.3...0.8,
                    targetPitchRange: -20...15,
                    maxRollDegrees: 4.0,
                    movementHint: "Estático",
                    directorTip: "Um café, azulejo, sinalética ou textura cria ritmo na edição."
                )
            ]
        ),
        ScenePack(
            id: "editorial-portrait",
            name: "Retrato Editorial",
            subtitle: "4 ângulos que valorizam rosto, postura e ambiente",
            iconName: "person.fill.viewfinder",
            shots: [
                ShotTemplate(
                    id: "prt-1",
                    title: "Retrato Ambiental",
                    kind: .establishing,
                    preferredMode: .photo,
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
                    targetDistanceRange: 1.3...2.2,
                    targetPitchRange: -5...8,
                    maxRollDegrees: 2.5,
                    movementHint: "Estático",
                    directorTip: "Enquadra dos joelhos/cintura para cima com a câmara à altura do peito."
                ),
                ShotTemplate(
                    id: "prt-3",
                    title: "Grande Plano",
                    kind: .closeUp,
                    preferredMode: .photo,
                    targetDistanceRange: 0.65...1.15,
                    targetPitchRange: -6...6,
                    maxRollDegrees: 2.5,
                    movementHint: "Estático",
                    directorTip: "Mantém a lente à altura dos olhos para proporções naturais."
                ),
                ShotTemplate(
                    id: "prt-4",
                    title: "Ângulo Herói",
                    kind: .lowAngle,
                    preferredMode: .video,
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
                    preferredMode: .photo,
                    targetDistanceRange: 2.0...4.2,
                    targetPitchRange: 6...22,
                    maxRollDegrees: 2.5,
                    movementHint: "Agachado junto aos faróis",
                    directorTip: "Baixa a câmara à altura do farol para o veículo parecer mais largo e agressivo."
                ),
                ShotTemplate(
                    id: "car-2",
                    title: "Reveal Lateral",
                    kind: .reveal,
                    preferredMode: .video,
                    targetDistanceRange: 1.4...3.0,
                    targetPitchRange: -4...10,
                    maxRollDegrees: 2.5,
                    movementHint: "Travelling lateral suave",
                    directorTip: "Percorre as linhas da carroçaria mantendo o horizonte travado."
                ),
                ShotTemplate(
                    id: "car-3",
                    title: "Detalhe Jante / Farol",
                    kind: .detail,
                    preferredMode: .video,
                    targetDistanceRange: 0.35...0.85,
                    targetPitchRange: -15...15,
                    maxRollDegrees: 3.5,
                    movementHint: "Push-in curto",
                    directorTip: "Foca reflexos, pinça de travão, emblema ou ótica."
                )
            ]
        ),
        ScenePack(
            id: "free-mode",
            name: "Modo Livre",
            subtitle: "Telemetria LiDAR + deteção automática de plano",
            iconName: "camera.metering.matrix",
            shots: []
        )
    ]
}
