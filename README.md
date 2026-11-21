# FramePilot — Realizador de Bolso para iPhone (LiDAR + ARKit)

App nativa iOS em **Swift + SwiftUI + ARKit (LiDAR) + CoreMotion** pensada para criadores de conteúdo (foto e vídeo).

## O que a v1 já faz
- **Medição real via LiDAR (`ARKit`):** mede a distância exata ao sujeito no centro do ecrã (em centímetros/metros).
- **Sensor de inclinação e horizonte (`CoreMotion`):** mede o ângulo vertical (*pitch*, picado vs. contrapicado) e o nivelamento do horizonte (*roll*) em modo vertical e horizontal.
- **Co-piloto em tempo real (`ShotCoachEngine`):** compara distância, ângulo e horizonte com o plano alvo e guia-te até a mira ficar verde (com feedback háptico).
- **Guiões de Cena prontos para criadores:**
  - *Reel Produto / UGC* (5 planos)
  - *Viagem & Rua* (4 planos)
  - *Retrato Editorial* (4 planos)
  - *Carro / Moto* (3 planos)
  - *Modo Livre* (telemetria LiDAR + deteção automática do tipo de plano)
- **Captura direta de Foto e Vídeo** para a galeria do iPhone, com avanço automático na checklist de planos.

---

## Como compilar e instalar GRÁTIS no iPhone (a partir do Windows)

### 1. Compilar o `.ipa` na cloud (0 € — sem Mac)
1. Cria um repositório no **GitHub** (podes criar público ou privado).
2. Faz `git push` desta pasta `framepilot/` para o repositório.
3. No GitHub, abre o separador **Actions** → o workflow **Build FramePilot IPA** corre automaticamente numa máquina `macos-15`.
4. Quando terminar (~3–5 min), descarrega o ficheiro **`FramePilot-unsigned-ipa`** em *Artifacts* e extrai o `FramePilot-unsigned.ipa`.

### 2. Instalar no teu iPhone (0 €)
1. Instala o **Sideloadly** (ou **AltStore / SideStore**) no teu Windows.
2. **Só na 1.ª vez:** liga o iPhone ao PC por cabo USB, confia no computador e ativa o **Modo de Programador** no iPhone (*Definições → Privacidade e Segurança → Modo de Programador*).
3. Arrasta o `FramePilot-unsigned.ipa` para o Sideloadly, coloca o teu Apple ID gratuito e clica em **Start**.
4. No iPhone, vai a *Definições → Geral → VPN e Gestão de Dispositivos* e confia no teu perfil.
5. Depois desta 1.ª instalação, ativa a opção de **Wi-Fi** no Sideloadly/AltStore para atualizações e renovações sem cabo.
