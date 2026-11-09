# JARVIS MIDAS — llamada de voz continua (iOS nativo)

Dos piezas:

- **`ios/`**: app SwiftUI para iPhone (iOS 17+). Escucha, detecta cuándo terminas de hablar, ejecuta acciones y responde con voz.
- **`backend/`**: servidor Node sin dependencias. Guarda tu clave de Anthropic y habla con Claude. Usa búsqueda web real y streaming.

La clave de la IA **nunca** está en el iPhone. La app solo guarda la URL del servidor y un token propio, en el Llavero de iOS.

---

## 1. Poner en marcha el servidor

Requisitos: Node 18 o superior y una clave de la API de Anthropic (console.anthropic.com).

```bash
cd backend
export ANTHROPIC_API_KEY=sk-ant-...
export JARVIS_DEVICE_TOKEN=$(openssl rand -hex 32)   # guárdalo: lo pegarás en la app
npm start                                            # escucha en :8787
curl http://localhost:8787/health
```

Para el iPhone necesitas una URL **https**. Puedes desplegarlo así:

1. Sube la carpeta `backend` a Render, Railway, Fly.io o un VPS con un proxy TLS.
2. Define `ANTHROPIC_API_KEY` y `JARVIS_DEVICE_TOKEN` como variables de entorno del servicio. Nunca las subas al repositorio.
3. Opcional: `JARVIS_MODEL`. Por defecto es `claude-sonnet-5-5`, por su baja latencia en voz; `claude-opus-5-5` responde con más profundidad pero más lento.

## 2. Compilar la app

Requisitos: un Mac con Xcode 16 o superior, un iPhone con iOS 17 o superior y un Apple ID. Con la cuenta gratuita la app caduca a los 7 días. Con el Apple Developer Program (99 €/año) no caduca y además puedes usar TestFlight.

```bash
brew install xcodegen
cd ios && xcodegen          # genera JarvisMidas.xcodeproj
open JarvisMidas.xcodeproj
```

1. En **Signing & Capabilities**, elige tu equipo y cambia el bundle id `com.midas.jarvis` por uno tuyo.
2. Conecta el iPhone y pulsa Run.
3. En la app, abre **Ajustes**, pega la URL del servidor y el token, y pulsa **Comprobar conexión**.
4. Recomendado para que Jarvis suene mejor: en el iPhone ve a Ajustes › Accesibilidad › Contenido leído › Voces › Español (España) y descarga una voz **Mejorada** o **Premium**, por ejemplo Jorge. Luego elígela en la app.

---

## 3. Cómo funciona la llamada

```
micrófono ─► AVAudioEngine (voice processing: cancelación de eco + ruido)
              ├─► SFSpeechRecognizer es-ES (en el dispositivo si es posible), parciales en vivo
              └─► VAD por energía con suelo de ruido adaptativo
                     │  fin de turno = silencio ~0,85 s (≈1,8 s si la frase queda a medias: "y…", "porque…")
                     ▼
         órdenes locales instantáneas (espera, repite, más despacio, continúa, abre X, cuelga)
                     │  todo lo demás ▼
         servidor ─► Claude (streaming) + búsqueda web + herramientas
                     │  texto ─► se habla frase a frase mientras llega (baja latencia)
                     │  acciones ─► la app las ejecuta y dice el resultado REAL
                     ▼
         AVSpeechSynthesizer → PCM → mismo motor de audio → el orbe sigue la amplitud real
                     ▼
         vuelve a escuchar sin tocar nada
```

- **Sin palabra clave dentro de la llamada.** «Jarvis, abre Spotify» y «abre Spotify» hacen lo mismo. La IA interpreta la intención; las frases locales son solo un atajo rápido.
- **Interrupciones (barge-in).** Puedes hablar mientras Jarvis habla. «Espera», «cállate un momento», «déjame hablar» o cualquier frase de tres palabras o más que no sea su propio eco lo cortan al instante. Lo que el micrófono capta de la voz de Jarvis se descarta para que nunca se tome como una orden. También puedes tocar el orbe.
- **Contexto.** Se envía todo el historial de la llamada, así que «¿y cuánto cuesta?», «hazlo otra vez» o «abre esa aplicación» se resuelven solos.
- **Memoria persistente.** Jarvis guarda preferencias, datos, proyectos y episodios con la herramienta `remember`. Se almacena cifrada en el iPhone y puedes verla, editarla, exportarla o borrarla en Ajustes.
- **Estados honestos.** «TE ESCUCHO» aparece solo si el reconocedor está activo de verdad. Si no, ves «MICRÓFONO INACTIVO» o «EN PAUSA».

### Acciones reales

| Lo que dices | Qué pasa de verdad |
|---|---|
| «Abre WhatsApp / Spoty / Insta / TikTok / Plex» | Se abre la app instalada; si no está, su web. Jarvis te dice cuál de las dos ocurrió. |
| «Pon música para conducir» | Spotify se abre con esa búsqueda. **Tienes que pulsar play**: Spotify no permite iniciar la reproducción desde otra app sin su SDK. |
| «Busca noticias de F1», «¿qué tiempo hace mañana?» | Búsqueda web real en el servidor. Jarvis resume y cita las fuentes, que aparecen como enlaces en la transcripción. |
| «Recuérdame llamar al taller mañana a las 10» | Crea un recordatorio con alarma en la app Recordatorios. |
| «Acuérdate de que…» / «olvida eso» | Memoria persistente. |
| «Traduce lo que diga esta persona en inglés» | Modo intérprete: escucha en inglés y te lo dice en español. «Sal del modo intérprete» lo desactiva. |
| «Repite», «más despacio», «continúa», «cuelga» | Se resuelven al instante, sin pasar por la red. |

---

## 4. Lo que iOS permite (sin trampas)

| Situación | ¿Funciona? |
|---|---|
| App abierta, llamada activa | Sí, todo. |
| Llamada activa y cambias de app (por ejemplo, Jarvis abre Spotify) | La sesión de audio sigue viva gracias al modo de audio en segundo plano. El punto naranja del micrófono queda visible. **Hay que comprobarlo en tu iPhone**: Apple no documenta que el reconocimiento de voz siga en segundo plano en todos los dispositivos. |
| Llamada activa y bloqueas el iPhone | Igual que el caso anterior. Con «Pantalla encendida durante la llamada» activado no hace falta bloquearlo. |
| Sin llamada: decir «Jarvis» con la app cerrada o el móvil bloqueado | **No.** Ninguna app de terceros puede escuchar siempre. La vía legítima es Siri: «Oye Siri, llama a Jarvis» abre la llamada. |
| Botón de Acción, Atajos, widgets | Atajos › «Llamar a Jarvis», o la URL `jarvismidas://call`. |
| Llamada telefónica, Siri o una alarma durante la conversación | Jarvis se pausa sin fingir que escucha y se reanuda al terminar. Si no puede, muestra «Reanudar». |

La app no enciende el micrófono fuera de una llamada que tú hayas iniciado.

---

## 5. Pruebas

**Probado aquí:** el servidor, contra un servidor de Anthropic simulado. Comprobé el rechazo sin token (401), el streaming de texto, el envío de acciones como `open_app` con su JSON troceado, el evento de búsqueda web, las fuentes, el modo coche, la memoria en el prompt y la fusión de turnos.

**No probado:** la app iOS. Este entorno no tiene Xcode ni iPhone, así que **no se ha compilado**. El código usa APIs estándar de iOS 17, pero es posible que Xcode marque algún error menor la primera vez. Si te pasa, pégame el error y lo corrijo.

Lista de comprobación en el dispositivo:

| # | Escenario | Qué verificar |
|---|---|---|
| 1 | Empezar la llamada y decir «Hola, Jarvis» | Saludo variado; luego «TE ESCUCHO». |
| 2 | Varias órdenes seguidas sin tocar la pantalla | Vuelve a escuchar tras cada respuesta. |
| 3 | Pregunta de seguimiento («¿y cuánto cuesta?») | Mantiene el contexto. |
| 4 | Interrumpir mientras habla («espera») | Se calla en menos de medio segundo. |
| 5 | «Repite eso» | Repite la última respuesta. |
| 6 | «Abre Spotify» | Se abre, o te dice con verdad que no pudo. |
| 7 | «Busca las últimas noticias de Fórmula 1» | «EJECUTANDO», luego un resumen con fuentes. |
| 8 | Hablar con pausas («quiero… mmm… saber») | No corta a mitad de frase. |
| 9 | Ruido de fondo (tele, coche) | No responde al ruido solo. |
| 10 | Denegar el micrófono | Mensaje claro; nunca muestra «TE ESCUCHO». |
| 11 | Recibir una llamada a mitad de conversación | «EN PAUSA» y luego se reanuda. |
| 12 | Finalizar | El punto naranja del micrófono desaparece. |

Ajustes finos si hace falta: la sensibilidad de la detección de voz está en `SpeechInput.updateVAD` (+12 dB sobre el ruido) y el silencio de fin de turno en `baseSilence` (0,85 s).

## 6. Requisitos externos

- Clave de API de Anthropic, con facturación por uso.
- Un hosting con https para el servidor.
- Apple ID; para no tener que reinstalar cada 7 días, el Apple Developer Program.
- Opcional: Spotify iOS SDK (necesita un Client ID de Spotify) para poder reproducir, pausar y saltar canciones de verdad.
