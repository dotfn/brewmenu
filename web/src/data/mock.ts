// Realistic data for the HTML mocks of the app. Real formula names, real version shapes.

export const outdated = [
  { name: "gh", from: "2.97.0", to: "2.98.1" },
  { name: "libffi", from: "3.7.1", to: "3.8.0" },
  { name: "mise", from: "2026.8.2", to: "2026.8.3" },
  { name: "opencode", from: "1.18.10", to: "1.18.15" },
  { name: "stats", from: "3.0.10", to: "3.0.11", cask: true },
];

export const services = [
  { name: "postgresql@18", running: true },
  { name: "cloudflared", running: false },
];

export const apps = [
  { name: "Ghostty", token: "ghostty", version: "1.2.3", size: "142 MB", hue: 230 },
  { name: "Raycast", token: "raycast", version: "1.104.1", size: "318 MB", hue: 5 },
  { name: "Rectangle", token: "rectangle", version: "0.91", size: "11 MB", hue: 200 },
  { name: "Stats", token: "stats", version: "3.0.10", size: "17 MB", hue: 150, outdated: "3.0.11" },
  { name: "Visual Studio Code", token: "visual-studio-code", version: "1.131.0", size: "612 MB", hue: 210 },
  { name: "Zed", token: "zed", version: "0.210.4", size: "256 MB", hue: 260 },
];

export const disk = [
  { name: "go", size: "254 MB", pct: 100 },
  { name: "node", size: "98 MB", pct: 39 },
  { name: "python@3.14", size: "74 MB", pct: 29 },
  { name: "ffmpeg", size: "52 MB", pct: 20 },
  { name: "gh", size: "38 MB", pct: 15 },
  { name: "ripgrep", size: "6.4 MB", pct: 3 },
];
