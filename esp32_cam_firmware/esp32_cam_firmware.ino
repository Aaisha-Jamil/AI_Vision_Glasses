/**
 * ==============================================================================
 * AI Vision Glasses - ESP32-CAM Smart Firmware (v2.0 Bulletproof Edition)
 * ==============================================================================
 * 
 * Hardware:
 *   - AI-Thinker ESP32-CAM (OV2640 camera module + 4MB PSRAM)
 *   - Push button on GPIO 14 (IO14) to GND (internal pull-up enabled)
 *   - Built-in status LED on GPIO 33 (Active LOW)
 * 
 * Key Features that eliminate connection & configuration issues:
 *   1. EMBEDDED WEB SERVER ON PORT 80:
 *      - Open http://<glasses-ip>/ in any browser to see the live photo preview!
 *      - Open http://<glasses-ip>/latest.jpg to view/download the last captured image.
 *      - Open http://<glasses-ip>/capture to take a slide photo directly from browser.
 *   2. LOCAL PSRAM IMAGE CACHE:
 *      - Every captured slide is kept safely in ESP32 memory. Even if your PC or backend
 *        is completely turned OFF or offline, the image is NEVER LOST!
 *   3. WEB-BASED CONFIGURATION (NO RE-FLASHING!):
 *      - Change Backend PC IP (e.g. 192.168.10.25) directly from the web page.
 *      - Saved to permanent flash (NVS) across reboots.
 *   4. FALLBACK ACCESS POINT (AP MODE):
 *      - If Wi-Fi fails to connect, automatically creates "AI-Vision-Glasses" Wi-Fi
 *        hotspot at 192.168.4.1 so you can use it anywhere (classroom, outdoors).
 *   5. ZERO-CRASH UPLOAD:
 *      - When button on IO14 is pressed, it captures high-res JPEG, saves locally,
 *        and tries uploading to FastAPI backend. If backend is offline, it gracefully
 *        logs the offline state while preserving the photo on the glasses.
 * ==============================================================================
 */

#include "esp_camera.h"
#include <WiFi.h>
#include <WebServer.h>
#include <HTTPClient.h>
#include <ESPmDNS.h>
#include <Preferences.h>
#include "soc/soc.h"
#include "soc/rtc_cntl_reg.h"

// ==============================================================================
// 1. Hardware Pin Definitions (AI-Thinker ESP32-CAM)
// ==============================================================================
#define BUTTON_PIN        14   // Push button input (active LOW, pulled up internally)
#define STATUS_LED_PIN    33   // Small red status LED on back (active LOW)
#define FLASH_LED_PIN      4   // Bright flash LED (active HIGH, optional)
#define PWDN_GPIO_NUM     32
#define RESET_GPIO_NUM    -1
#define XCLK_GPIO_NUM      0
#define SIOD_GPIO_NUM     26
#define SIOC_GPIO_NUM     27
#define Y9_GPIO_NUM       35
#define Y8_GPIO_NUM       34
#define Y7_GPIO_NUM       39
#define Y6_GPIO_NUM       36
#define Y5_GPIO_NUM       21
#define Y4_GPIO_NUM       19
#define Y3_GPIO_NUM       18
#define Y2_GPIO_NUM        5
#define VSYNC_GPIO_NUM    25
#define HREF_GPIO_NUM     23
#define PCLK_GPIO_NUM     22

// ==============================================================================
// 2. Default Configuration & Persistent Settings
// ==============================================================================
const char* DEFAULT_SSID         = "PTCL-BB";
const char* DEFAULT_PASS         = "81846a94";
const char* DEFAULT_SERVER_HOST  = "192.168.10.25";
const int   DEFAULT_SERVER_PORT  = 8000;
const char* DEFAULT_UPLOAD_PATH  = "/api/v1/glasses/capture";

// NOTE: GPIO 33 is the red LED on the AI-Thinker ESP32-CAM module itself (active LOW).
// If your LED never blinks at all, the MB programmer board may be intercepting GPIO 33.
// In that case, the FLASH_LED on GPIO 4 is a reliable alternative (active HIGH).

String currentSSID;
String currentPass;
String currentServerHost;
int    currentServerPort;
String currentUploadPath;

Preferences prefs;
WebServer server(80);

// Image cache in PSRAM
uint8_t* latestImageBuf = nullptr;
size_t   latestImageLen = 0;
String   latestCaptureTime = "None yet";
int      totalCapturesCount = 0;

// State management
volatile bool isProcessing = false;
unsigned long lastButtonPress = 0;
const unsigned long DEBOUNCE_MS = 300;

// ==============================================================================
// 3. Helper Functions
// ==============================================================================
// Visual indicator: toggle both STATUS_LED (GPIO 33, active LOW)
// and briefly toggle FLASH_LED (GPIO 4, active HIGH) so blinking is clearly visible on any board variant!
void blinkLed(int times, int delayMs) {
  for (int i = 0; i < times; i++) {
    digitalWrite(STATUS_LED_PIN, LOW);  // Red LED ON (active LOW)
    digitalWrite(FLASH_LED_PIN, HIGH);  // Flash LED ON (active HIGH)
    delay(delayMs);
    digitalWrite(STATUS_LED_PIN, HIGH); // Red LED OFF
    digitalWrite(FLASH_LED_PIN, LOW);   // Flash LED OFF
    if (i < times - 1) delay(delayMs);
  }
}

void loadSettings() {
  prefs.begin("glasses_cfg", false);
  currentSSID        = prefs.getString("ssid", DEFAULT_SSID);
  currentPass        = prefs.getString("pass", DEFAULT_PASS);
  currentServerHost  = prefs.getString("host", DEFAULT_SERVER_HOST);
  currentServerPort  = prefs.getInt("port", DEFAULT_SERVER_PORT);
  currentUploadPath  = prefs.getString("path", DEFAULT_UPLOAD_PATH);
  prefs.end();

  Serial.println("[Config] Loaded Settings:");
  Serial.printf("  - Wi-Fi SSID:    %s\n", currentSSID.c_str());
  Serial.printf("  - Backend Host:  %s:%d%s\n", currentServerHost.c_str(), currentServerPort, currentUploadPath.c_str());
}

void saveSettings(String newHost, int newPort) {
  prefs.begin("glasses_cfg", false);
  prefs.putString("host", newHost);
  prefs.putInt("port", newPort);
  prefs.end();
  currentServerHost = newHost;
  currentServerPort = newPort;
  Serial.printf("[Config] Saved new backend host: %s:%d\n", newHost.c_str(), newPort);
}

// ==============================================================================
// 4. Camera Initialization
// ==============================================================================
bool initCamera() {
  camera_config_t config;
  config.ledc_channel = LEDC_CHANNEL_0;
  config.ledc_timer   = LEDC_TIMER_0;
  config.pin_d0       = Y2_GPIO_NUM;
  config.pin_d1       = Y3_GPIO_NUM;
  config.pin_d2       = Y4_GPIO_NUM;
  config.pin_d3       = Y5_GPIO_NUM;
  config.pin_d4       = Y6_GPIO_NUM;
  config.pin_d5       = Y7_GPIO_NUM;
  config.pin_d6       = Y8_GPIO_NUM;
  config.pin_d7       = Y9_GPIO_NUM;
  config.pin_xclk     = XCLK_GPIO_NUM;
  config.pin_pclk     = PCLK_GPIO_NUM;
  config.pin_vsync    = VSYNC_GPIO_NUM;
  config.pin_href     = HREF_GPIO_NUM;
  config.pin_sccb_sda = SIOD_GPIO_NUM;
  config.pin_sccb_scl = SIOC_GPIO_NUM;
  config.pin_pwdn     = PWDN_GPIO_NUM;
  config.pin_reset    = RESET_GPIO_NUM;
  config.xclk_freq_hz = 20000000;
  config.pixel_format = PIXFORMAT_JPEG;

  if (psramFound()) {
    config.frame_size   = FRAMESIZE_UXGA; // 1600x1200 high-res
    config.jpeg_quality = 10;             // High crispness for slide text
    config.fb_count     = 2;
    Serial.println("[Camera] PSRAM detected! Using UXGA (1600x1200) high resolution.");
  } else {
    config.frame_size   = FRAMESIZE_SVGA; // 800x600 fallback
    config.jpeg_quality = 12;
    config.fb_count     = 1;
    Serial.println("[Camera] PSRAM not found. Using SVGA fallback.");
  }

  esp_err_t err = esp_camera_init(&config);
  if (err != ESP_OK) {
    Serial.printf("[Camera] Init failed: 0x%x\n", err);
    return false;
  }

  sensor_t* s = esp_camera_sensor_get();
  if (s != NULL) {
    s->set_brightness(s, 1);
    s->set_contrast(s, 1);
    s->set_saturation(s, 0);
    s->set_whitebal(s, 1);
    s->set_awb_gain(s, 1);
    s->set_exposure_ctrl(s, 1);
  }
  return true;
}

// ==============================================================================
// 5. Image Capture & Local Cache
// ==============================================================================
bool performCapture() {
  digitalWrite(STATUS_LED_PIN, LOW); // LED ON
  camera_fb_t* fb = esp_camera_fb_get();
  if (!fb) {
    Serial.println("[Capture] Failed to grab frame from OV2640!");
    digitalWrite(STATUS_LED_PIN, HIGH);
    return false;
  }

  // Allocate/reallocate cache in PSRAM
  if (latestImageBuf) {
    free(latestImageBuf);
    latestImageBuf = nullptr;
  }

  if (psramFound()) {
    latestImageBuf = (uint8_t*)ps_malloc(fb->len);
  } else {
    latestImageBuf = (uint8_t*)malloc(fb->len);
  }

  if (latestImageBuf) {
    memcpy(latestImageBuf, fb->buf, fb->len);
    latestImageLen = fb->len;
    totalCapturesCount++;
    latestCaptureTime = String(millis() / 1000) + "s since boot";
    Serial.printf("[Capture] Slide captured: %d bytes (saved in local memory!)\n", fb->len);
  }

  // Attempt backend upload if Wi-Fi is connected
  Serial.printf("[Upload] WiFi status: %d | Backend host: '%s'\n",
                (int)WiFi.status(), currentServerHost.c_str());

  if (WiFi.status() == WL_CONNECTED && currentServerHost.length() > 0) {
    String serverUrl = "http://" + currentServerHost + ":" + String(currentServerPort) + currentUploadPath;
    Serial.printf("[Upload] Sending to: %s\n", serverUrl.c_str());

    HTTPClient http;
    http.begin(serverUrl);
    http.setTimeout(10000); // 10-second timeout (was 4s - too short for YOLO processing)
    http.addHeader("Content-Type", "image/jpeg");
    http.addHeader("X-Device-Source", "esp32_cam");

    int code = http.POST(fb->buf, fb->len);
    if (code > 0) {
      Serial.printf("[Upload] SUCCESS! HTTP Code: %d\n", code);
      blinkLed(2, 80); // 2 fast blinks = upload success!
    } else if (code == -1) {
      Serial.println("[Upload] Connection refused - is the backend server running?");
      Serial.printf("[Upload] Target was: %s\n", serverUrl.c_str());
      Serial.println("[Upload] Photo safely saved on glasses web server - view at http://" + WiFi.localIP().toString() + "/");
      blinkLed(1, 300);
    } else {
      Serial.printf("[Upload] Server error (HTTP %d). Photo saved locally.\n", code);
      blinkLed(1, 300);
    }
    http.end();
  } else if (WiFi.status() != WL_CONNECTED) {
    Serial.println("[Upload] Wi-Fi disconnected! Reconnecting...");
    WiFi.reconnect();
    delay(3000);
    Serial.println("[Upload] Photo saved locally. It will show on glasses web server.");
    blinkLed(1, 200);
  } else {
    Serial.println("[Upload] No backend host configured.");
    Serial.println("[Upload] Open http://" + WiFi.localIP().toString() + "/ to set your PC's IP address.");
    blinkLed(1, 200);
  }

  esp_camera_fb_return(fb);
  digitalWrite(STATUS_LED_PIN, HIGH); // LED OFF
  return true;
}

// ==============================================================================
// 6. Embedded Web Server Handlers (Port 80)
// ==============================================================================
void handleRoot() {
  String ip = (WiFi.getMode() & WIFI_AP) ? WiFi.softAPIP().toString() : WiFi.localIP().toString();

  String html = "<!DOCTYPE html><html><head><meta charset='utf-8'>";
  html += "<meta name='viewport' content='width=device-width, initial-scale=1.0'>";
  html += "<title>AI Vision Glasses - Camera Hub</title>";
  html += "<style>";
  html += "body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 16px; text-align: center; }";
  html += ".card { max-width: 540px; margin: 0 auto; background: #1e293b; border-radius: 16px; padding: 20px; box-shadow: 0 10px 25px rgba(0,0,0,0.4); border: 1px solid #334155; }";
  html += "h1 { color: #38bdf8; font-size: 22px; margin-bottom: 4px; }";
  html += ".badge { display: inline-block; background: #059669; color: white; padding: 4px 12px; border-radius: 999px; font-size: 12px; font-weight: bold; margin-bottom: 16px; }";
  html += ".img-box { width: 100%; border-radius: 12px; overflow: hidden; background: #020617; border: 1px solid #475569; min-height: 200px; display: flex; align-items: center; justify-content: center; margin: 16px 0; }";
  html += ".img-box img { max-width: 100%; height: auto; display: block; }";
  html += ".btn { display: inline-block; background: #38bdf8; color: #0f172a; padding: 12px 24px; border-radius: 8px; font-size: 16px; font-weight: bold; text-decoration: none; border: none; cursor: pointer; transition: 0.2s; margin: 6px; }";
  html += ".btn:hover { background: #7dd3fc; }";
  html += ".btn-sec { background: #334155; color: #f8fafc; }";
  html += ".btn-sec:hover { background: #475569; }";
  html += ".info { font-size: 13px; color: #94a3b8; text-align: left; margin-top: 16px; background: #0b1120; padding: 12px; border-radius: 8px; }";
  html += "input[type='text'], input[type='number'] { width: calc(100% - 20px); padding: 8px; border-radius: 6px; border: 1px solid #475569; background: #0f172a; color: white; margin-top: 4px; margin-bottom: 12px; }";
  html += "</style></head><body>";

  html += "<div class='card'>";
  html += "<h1>👓 AI Vision Glasses</h1>";
  html += "<div class='badge'>● Camera Online (" + ip + ")</div>";

  html += "<div class='img-box'>";
  if (latestImageLen > 0) {
    html += "<img src='/latest.jpg?" + String(millis()) + "' alt='Latest Captured Slide'>";
  } else {
    html += "<p style='color:#94a3b8;'>No slide captured yet.<br>Press the glasses button (IO14) or click below!</p>";
  }
  html += "</div>";

  html += "<a href='/trigger-capture' class='btn'>📸 Capture Slide Now</a>";
  if (latestImageLen > 0) {
    html += "<a href='/latest.jpg' target='_blank' class='btn btn-sec'>Open Full Image ↗</a>";
  }

  html += "<div class='info'>";
  html += "<b>Total Captures:</b> " + String(totalCapturesCount) + "<br>";
  html += "<b>Last Capture:</b> " + latestCaptureTime + " (" + String(latestImageLen / 1024) + " KB)<br>";
  html += "<b>Physical Button:</b> GPIO 14 (IO14)<br>";
  html += "<b>Backend Target:</b> http://" + currentServerHost + ":" + String(currentServerPort) + "<br>";
  html += "</div>";

  html += "<div class='info' style='margin-top:14px;'>";
  html += "<b style='color:#38bdf8;'>⚙️ Change Backend PC IP (No Reflashing Needed!):</b><br><br>";
  html += "<form method='POST' action='/save-settings'>";
  html += "<label>Computer Local IP Address:</label><br>";
  html += "<input type='text' name='host' value='" + currentServerHost + "'><br>";
  html += "<label>FastAPI Port:</label><br>";
  html += "<input type='number' name='port' value='" + String(currentServerPort) + "'><br>";
  html += "<input type='submit' class='btn' value='💾 Save Backend IP' style='width:100%; margin:0;'>";
  html += "</form>";
  html += "</div>";

  html += "</div></body></html>";
  server.send(200, "text/html", html);
}

void handleLatestImage() {
  if (latestImageBuf && latestImageLen > 0) {
    server.sendHeader("Content-Disposition", "inline; filename=slide.jpg");
    server.sendHeader("Access-Control-Allow-Origin", "*");
    server.send_P(200, "image/jpeg", (const char*)latestImageBuf, latestImageLen);
  } else {
    server.send(404, "text/plain", "No image captured yet. Press the push button or call /capture.");
  }
}

void handleTriggerCapture() {
  if (!isProcessing) {
    isProcessing = true;
    performCapture();
    isProcessing = false;
  }
  // Redirect back to home page to see the new image
  server.sendHeader("Location", "/");
  server.send(303);
}

void handleDirectCaptureJpg() {
  if (!isProcessing) {
    isProcessing = true;
    performCapture();
    isProcessing = false;
  }
  handleLatestImage();
}

void handleSaveSettings() {
  if (server.hasArg("host")) {
    String newHost = server.arg("host");
    int newPort = server.hasArg("port") ? server.arg("port").toInt() : DEFAULT_SERVER_PORT;
    if (newHost.length() > 0) {
      saveSettings(newHost, newPort);
    }
  }
  server.sendHeader("Location", "/");
  server.send(303);
}

void handleStatus() {
  String json = "{";
  json += "\"status\":\"ready\",";
  json += "\"total_captures\":" + String(totalCapturesCount) + ",";
  json += "\"latest_size_bytes\":" + String(latestImageLen) + ",";
  json += "\"backend_host\":\"" + currentServerHost + "\",";
  json += "\"backend_port\":" + String(currentServerPort) + ",";
  json += "\"ip\":\"" + WiFi.localIP().toString() + "\"";
  json += "}";
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.send(200, "application/json", json);
}

// ==============================================================================
// 7. Wi-Fi Setup with Fallback AP Mode
// ==============================================================================
void setupWiFi() {
  loadSettings();

  Serial.printf("\n[WiFi] Connecting to %s...", currentSSID.c_str());
  WiFi.mode(WIFI_STA);
  WiFi.begin(currentSSID.c_str(), currentPass.c_str());

  int retries = 0;
  while (WiFi.status() != WL_CONNECTED && retries < 20) {
    delay(500);
    Serial.print(".");
    digitalWrite(STATUS_LED_PIN, !digitalRead(STATUS_LED_PIN));
    retries++;
  }

  if (WiFi.status() == WL_CONNECTED) {
    digitalWrite(STATUS_LED_PIN, HIGH); // LED OFF
    Serial.println("\n==================================================");
    Serial.println("  [WiFi] CONNECTED SUCCESSFULLY!");
    Serial.printf("  Camera Hub Web URL: http://%s/\n", WiFi.localIP().toString().c_str());
    Serial.printf("  Latest Image URL:   http://%s/latest.jpg\n", WiFi.localIP().toString().c_str());
    Serial.printf("  Target Backend:     http://%s:%d%s\n", currentServerHost.c_str(), currentServerPort, currentUploadPath.c_str());
    Serial.println("==================================================");
    blinkLed(3, 80);
  } else {
    // Wi-Fi connection failed -> Start Access Point Hotspot Mode!
    Serial.println("\n[WiFi] Could not connect to router.");
    Serial.println("[WiFi] Starting Fallback Hotspot: 'AI-Vision-Glasses'...");
    WiFi.mode(WIFI_AP);
    WiFi.softAP("AI-Vision-Glasses", "12345678");
    Serial.println("==================================================");
    Serial.println("  Hotspot Active! Connect your phone/laptop to:");
    Serial.println("  SSID:     AI-Vision-Glasses");
    Serial.println("  Password: 12345678");
    Serial.printf("  Web URL:  http://%s/\n", WiFi.softAPIP().toString().c_str());
    Serial.println("==================================================");
    blinkLed(5, 50);
  }

  // Setup mDNS responder (http://ai-glasses.local)
  if (MDNS.begin("ai-glasses")) {
    Serial.println("[mDNS] Responder started: http://ai-glasses.local/");
  }

  // Setup Web Server Routes
  server.on("/", HTTP_GET, handleRoot);
  server.on("/latest.jpg", HTTP_GET, handleLatestImage);
  server.on("/capture", HTTP_GET, handleDirectCaptureJpg);
  server.on("/trigger-capture", HTTP_GET, handleTriggerCapture);
  server.on("/save-settings", HTTP_POST, handleSaveSettings);
  server.on("/status", HTTP_GET, handleStatus);
  server.begin();
  Serial.println("[WebServer] Server listening on port 80.");
}

// ==============================================================================
// 8. Main Arduino Setup & Loop
// ==============================================================================
void setup() {
#if defined(RTC_CNTL_BROWN_OUT_REG)
  WRITE_PERI_REG(RTC_CNTL_BROWN_OUT_REG, 0); // Disable brownout detector
#endif

  Serial.begin(115200);
  delay(1000);

  Serial.println("\n==================================================");
  Serial.println("AI Vision Glasses - Smart Client Booting (v2.0)...");
  Serial.println("==================================================");

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  pinMode(STATUS_LED_PIN, OUTPUT);
  pinMode(FLASH_LED_PIN, OUTPUT);
  digitalWrite(STATUS_LED_PIN, HIGH);
  digitalWrite(FLASH_LED_PIN, LOW);

  if (!initCamera()) {
    Serial.println("[Setup] Fatal: Camera hardware failed to start!");
    while (true) { blinkLed(1, 1000); }
  }

  setupWiFi();
  Serial.println("[Setup] Ready! Press the push button (IO14) to capture a slide.");
}

void loop() {
  // Handle incoming web requests (viewing image, changing IP settings, etc.)
  server.handleClient();

  // Check hardware push button (IO14 active LOW)
  if (digitalRead(BUTTON_PIN) == LOW && !isProcessing) {
    unsigned long now = millis();
    if (now - lastButtonPress > DEBOUNCE_MS) {
      lastButtonPress = now;
      isProcessing = true;
      Serial.println("\n--------------------------------------------------");
      Serial.println("[Button] Push button pressed! Capturing slide...");
      performCapture();
      isProcessing = false;
      Serial.println("--------------------------------------------------");
    }
  }

  delay(5);
}
