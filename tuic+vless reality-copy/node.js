#!/usr/bin/env node
const fs = require('fs');
const { execSync } = require('child_process');

const MASQ_DOMAIN = 'www.bing.com';
const TUIC_TOML = './server.toml';
const TUIC_CERT = './tuic-cert.pem';
const TUIC_KEY = './tuic-key.pem';
const TUIC_LINK = './tuic_link.txt';
const XRAY_CONF = './xray.json';
const VLESS_INFO = './vless_reality_info.txt';
const REALITY_KEYS_FILE = './reality_keys.json';

function genUUID() {
  try {
    return execSync('cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen || openssl rand -hex 16').toString().trim();
  } catch {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx';
  }
}

function randomPort() {
  return Math.floor(Math.random() * 40000) + 20000;
}

// ===== TUIC 配置生成 =====
const TUIC_PORT = process.env.SERVER_PORT || randomPort();
const TUIC_UUID = genUUID();
const TUIC_PASSWORD = execSync('openssl rand -hex 16').toString().trim();

function generateTuicCert() {
  if (!fs.existsSync(TUIC_CERT) || !fs.existsSync(TUIC_KEY)) {
    execSync(`openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout "${TUIC_KEY}" -out "${TUIC_CERT}" -subj "/CN=${MASQ_DOMAIN}" -addext "subjectAltName=DNS:${MASQ_DOMAIN}" -sha256 -days 365 -nodes`);
    fs.chmodSync(TUIC_KEY, 0o600);
    fs.chmodSync(TUIC_CERT, 0o644);
  }
}

function generateTuicConfig() {
  const content = `
log_level = "warn"
server = "0.0.0.0:${TUIC_PORT}"
udp_relay_ipv6 = false
zero_rtt_handshake = true
dual_stack = false
auth_timeout = "8s"
gc_interval = "8s"
gc_lifetime = "8s"
max_external_packet_size = 8192

[users]
${TUIC_UUID} = "${TUIC_PASSWORD}"

[tls]
certificate = "${TUIC_CERT}"
private_key = "${TUIC_KEY}"
alpn = ["h3"]
  `;
  fs.writeFileSync(TUIC_TOML, content);
}

function generateTuicLink() {
  const IP = execSync('curl -4 -s https://api.ipify.org || echo 127.0.0.1').toString().trim();
  // URI 中 IPv6 主机必须使用方括号；allow_insecure 是 TUIC v5 通用参数名。
  const host = IP.includes(':') && !IP.startsWith('[') ? `[${IP}]` : IP;
  const content = `tuic://${encodeURIComponent(TUIC_UUID)}:${encodeURIComponent(TUIC_PASSWORD)}@${host}:${TUIC_PORT}?congestion_control=bbr&alpn=h3&allow_insecure=1&sni=${encodeURIComponent(MASQ_DOMAIN)}&udp_relay_mode=native#TUIC-${encodeURIComponent(IP)}`;
  fs.writeFileSync(TUIC_LINK, content);
  console.log('🔗 TUIC 链接:\n' + content);
}

// ===== VLESS Reality 配置生成 =====
const VLESS_UUID = genUUID();

if (!fs.existsSync(REALITY_KEYS_FILE)) {
  console.error(`❌ reality_keys.json 不存在，请先生成 PrivateKey / PublicKey`);
  process.exit(1);
}

const keys = JSON.parse(fs.readFileSync(REALITY_KEYS_FILE, 'utf-8'));

function generateVlessConfig() {
  const conf = {
    log: { loglevel: 'warning' },
    inbounds: [{
      listen: '0.0.0.0',
      port: 443,
      protocol: 'vless',
      settings: { clients: [{ id: VLESS_UUID, flow: 'xtls-rprx-vision' }], decryption: 'none' },
      streamSettings: {
        network: 'tcp',
        security: 'reality',
        realitySettings: {
          show: false,
          dest: `${MASQ_DOMAIN}:443`,
          xver: 0,
          serverNames: [MASQ_DOMAIN],
          privateKey: keys.privateKey,
          shortIds: ['']
        }
      }
    }],
    outbounds: [{ protocol: 'freedom' }]
  };
  fs.writeFileSync(XRAY_CONF, JSON.stringify(conf, null, 2));
}

function generateVlessLink() {
  const IP = execSync('curl -s https://api64.ipify.org || echo 127.0.0.1').toString().trim();
  const content = `VLESS Reality 节点信息
UUID: ${VLESS_UUID}
PrivateKey: ${keys.privateKey}
PublicKey: ${keys.publicKey}
SNI: ${MASQ_DOMAIN}
Port: 443
Link:
vless://${VLESS_UUID}@${IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${MASQ_DOMAIN}&fp=chrome&pbk=${keys.publicKey}#VLESS-REALITY
`;
  fs.writeFileSync(VLESS_INFO, content);
  console.log(content);
}

// ===== 执行生成 =====
generateTuicCert();
generateTuicConfig();
generateTuicLink();
generateVlessConfig();
generateVlessLink();

console.log('🎉 配置文件生成完成！请使用下面的启动脚本启动 TUIC + VLESS Reality');
