<img width="2555" height="1432" alt="image" src="https://github.com/user-attachments/assets/4f3f9448-bb60-4daa-a7d7-17d7166e4942" /><img width="2555" height="1432" alt="image" src="https://github.com/user-attachments/assets/f6b1d0c9-17a7-46de-b810-9116c02202d8" /># 1.Hysteria2在Nodejs/Python一键脚本极简部署（Pterodactyl 翼龙面板）

* 更新自适应端口，无需再手动设置

* Hysteria2版本：2.6.5 官方更新说明（原文直译）：

  修复了随着每个客户端连接而累积的服务器端内存泄漏问题
  
* 安装脚本
```
bash <(curl -Ls https://raw.githubusercontent.com/gaathub/tuic-hy2-node.js-python/refs/heads/main/hy2.sh | sed 's/\r$//')
```
* 卸载脚本
```
bash <(curl -Ls https://raw.githubusercontent.com/gaathub/tuic-hy2-node.js-python/refs/heads/main/hy2.sh | sed 's/\r$//') del
```


---------------------------------------

# 2.TUIC在Nodejs/Python一键脚本极简部署（Pterodactyl 翼龙面板）

* 自适应端口，无需再手动设置

* TUIC版本：1.4.5 官方更新说明（原文直译）：

  🐛 错误修复
     （服务器）发送 FIN 以作废stream reset by peer

   ⚙️ 杂项任务
      将日志更改为跟踪

```
curl -Ls https://raw.githubusercontent.com/eishare/tuic-hy2-node.js-python/main/tuic.sh | sed 's/\r$//' | bash
```

