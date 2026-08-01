部署到宝塔站点：

  /www/wwwroot/tool.a-cheng.cn/ramdisk/activate/

结构：

  activate/ticket.php
  activate/tickets/{ECID}.zip
  activate/tickets/{ECID}/
    activation_records/activation_record.plist   ★ 必须
    data_ark.plist                               可选
    IC-Info.sisv                                 推荐（FairPlay）
    IC-Info.sidv                                 可选
    FairPlay/iTunes_Control/iTunes/IC-Info.sisv  可选布局
    com.apple.commcenter.device_specific_nobackup.plist  可选（基带）

客户端：
  https://tool.a-cheng.cn/ramdisk/activate/ticket.php?ecid=...
  https://tool.a-cheng.cn/ramdisk/activate/tickets/{ECID}.zip

本地调试：
  文档\AC-Tools\ActivationTickets\{ECID}\

票必须来自「同一台已激活设备」备份，不要放伪造/无关机票。
