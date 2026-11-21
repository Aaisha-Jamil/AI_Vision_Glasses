# 🕶️ AI Vision Glasses - ESP32-CAM Smart Firmware (v2.0)

This directory contains the upgraded, bulletproof Arduino C++ firmware for the **AI Vision Glasses** hardware module:
- **Board**: AI-Thinker ESP32-CAM (OV2640 2MP + 4MB PSRAM)
- **Programmer**: ESP32-CAM-MB daughterboard (CH340 Micro-USB)
- **Physical Button**: Push Button on GPIO 14 (IO14) to GND

---

## 🚀 Key Improvements in v2.0

1. **Embedded Web Server on Port 80**:
   - Open `http://<glasses-ip>/` (e.g. `http://192.168.10.26/`) in **any** browser on phone or PC to view the live camera control hub!
   - View the latest captured slide photo immediately.
   - Click "📸 Capture Slide Now" directly from your phone/browser.
2. **Local PSRAM Image Cache**:
   - Every slide captured is safely stored in ESP32 memory. Even if your PC or backend is offline, **photos are never lost**.
   - Direct image link: `http://<glasses-ip>/latest.jpg`
3. **Web-Based IP Configuration (NO RE-FLASHING!)**:
   - If your computer's IP changes (e.g. `192.168.10.25`), simply open `http://<glasses-ip>/` in your browser, enter the new IP, and click **Save**. It saves to permanent ESP32 flash (NVS) across reboots!
4. **Fallback Hotspot (AP Mode)**:
   - If Wi-Fi fails to connect, the glasses automatically create a Wi-Fi hotspot named `AI-Vision-Glasses` (Password: `12345678`) at `192.168.4.1` for standalone use in classrooms or outdoors.
5. **mDNS Support**:
   - Reachable via `http://ai-glasses.local/` on supported devices.

---

## 🔌 Hardware Wiring Diagram

```text
       +--------------------------------------------+
       |             ESP32-CAM Module               |
       |                                            |
       |  [OV2640 Lens]                             |
       |                                            |
       |         [IO14 / GPIO 14] -----------+      |
       |         [GND]            -----+     |      |
       +-------------------------------+-----+------+
                                       |     |
                                    +--+--+  |
                                    |     |  |
                                    | [o] |--+  <-- Push Button (Normally Open)
                                    |     |
                                    +-----+
```

1. **Button Pin 1**: Connect to **IO14** (GPIO 14) on the ESP32-CAM.
2. **Button Pin 2**: Connect to **GND** on the ESP32-CAM.
3. **Power**: Plug your USB cable into the **ESP32-CAM-MB** programmer board.

---

## 💻 Arduino IDE Flashing Instructions

### 1. Board Settings in Tools Menu
* **Board**: `AI Thinker ESP32-CAM`
* **CPU Frequency**: `240MHz (WiFi/BT)`
* **Flash Frequency**: `80MHz`
* **Flash Mode**: `QIO`
* **Partition Scheme**: `Huge APP (3MB No OTA/1MB SPIFFS)`
* **Port**: Select the COM port of your ESP32 (e.g. `COM5`)

### 2. Upload
Click the **Upload** arrow in Arduino IDE. Once done, open the **Serial Monitor** at `115200` baud.

You will see:
```text
==================================================
AI Vision Glasses - Smart Client Booting (v2.0)...
==================================================
[Camera] PSRAM detected! Using UXGA (1600x1200) high resolution.
[WiFi] Connected to PTCL-BB!
Camera Hub Web URL: http://192.168.10.26/
Latest Image URL:   http://192.168.10.26/latest.jpg
[Setup] Ready! Press the push button (IO14) to capture a slide.
```

---

## 📱 How to Use

1. **Physical Capture**: Press the push button on pin **IO14** at any time.
2. **View in Browser**: Open `http://<glasses-ip>/` (e.g. `http://192.168.10.26/`) on your phone or PC to see the photo instantly!
3. **Full Resolution Photo**: Open `http://<glasses-ip>/latest.jpg`
4. **Change PC IP**: On the web page, scroll to **Change Backend PC IP**, type your computer's IP, and click **Save**.
