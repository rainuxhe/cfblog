+++
date = '2025-04-20T12:00:00+08:00'
draft = false
title = '安装Linux作为个人桌面系统'
description = '安装Linux作为个人桌面系统'
summary = '前几天实在受不了Windows11各种莫名其妙的卡顿和强制更新，所以决定先装个Linux双系统。'
isCJKLanguage = true
categories = ['life']
tags = ['other']
slug = 'install-linux-as-personal-desktop-system'
+++

前几天实在受不了Windows11各种莫名其妙的卡顿和强制更新，所以决定先装个Linux双系统，平时主用linux，有啥必须要用windows的时候再临时用用windows。

以前也装过双系统，用的发行版是Manjaro，实在用不惯pacman的包管理器，而且当时游戏瘾还比较重，因此就没怎么用过，有次Windows要重装，就把Manjaro给顺道卸载了。

其实更早之前大学时候，我的笔记本电脑只装了Fedora用了三年，后来大四做毕设，有些软件必须要用Windows。电脑系统换成windows后，之后就再没正儿八经把linux当个人主要的桌面系统。

这次打算装个Debian 12，1是因为个人平常用debian当服务器比较多，各种命令和配置都熟悉点，2是因为用户量大，有问题容易搜到，3是因为比较稳定，懒得折腾像Manjaro那些花里胡哨的玩法了。

## 一些配置记录

手头上有块闲置的固态盘，安装时候就把整块盘划给Debian了，简单分分区，然后按提示装Gnome桌面，这过程没什么好说的。需要注意的一点是Debian默认会联网搜索更新包，这特别慢，最好拔掉网线再安装，装完后再把网线接上。

系统刚安装后，桌面分辨率只有768P，但显示器是4K的，猜测是NVIDIA显卡驱动问题，所以按网上文档装了下显卡驱动，桌面分辨率也就正常了。

装显卡驱动之前最好先把apt源替换成国内镜像源，并且更新下系统和软件，免得安装驱动时下载依赖包很慢。我用的是清华源，虽然还没装中文输入法，但在浏览器按tsinghua mirror搜索一下就能找到。

然后安装中文输入法。我安装的时候选择的语言是英语，这样家目录下面的目录名就是英文的。如果安装时候选择的是中文，家目录下面的子目录也都是中文的，在命令行操作时候还得切中文输入法，比较麻烦。但装完系统后，可以另外安装中文语言包，提示要不要给家目录子目录重命名的时候，选择保留原名。中文输入法我一开始打算用搜狗输入法，但装上后怎么都切不出来，所以又卸载了，并且删除所有安装搜狗输入法时安装的`fcitx*`依赖包，另外安装`fcitx5`和`fcitx5-rime`，再去找了个雾凇输入法的配置文件来覆盖原rime的配置，这样中文输入法就配置好了。

接着安装一些常用软件：QQ、微信、VS Codium、Clash、WPS、Obsidian、滴答清单、XMind、YesPlayMusic（第三方网易云音乐播放器）、Wezterm、flameshot、MPV Player、OBS Studio、Git、Docker。

其中Wezterm我也是第一次用。Gnome自带的terminal不太好用，不支持右键粘贴等个性化配置，正好前几天看到过wezterm相关的博文，所以就装来试试看。按照官方文档简单配置了下，使用体验还是挺不错的。

还有一些gnome扩展也参考别人的配置装了下：

- AppIndicator and KStatusNotifierIterm Support，用来显示顶栏程序托盘图标
- Blur my Shell，美化Gnome的，提供一些类似毛玻璃的显示效果，装上后瞬间感觉现代化了不少
- Burn My Windows，提供一些窗口切换动画
- Dash to Dock, 托盘
- Gnome 4X UI Improvements
- Input Method Panel
- No overview at start-up
- NoAnnoyance v2，关闭一些 annoying 的 Gnome 提示

字体也换了，系统字体换成了思源黑体，等宽字体用的Maple Mono。剩下就是些微调，比如换换主题、图标，卸载些自带的不好玩的游戏，配置下开发环境等。

## 小结

用了几天，总体使用还是非常流畅的，不用再恶心Windows那破更新了，平常运行占用的资源也比较少，比较安静。我的电脑配置是CPU 24核，内存64GB，三块固态盘+一块机械仓库盘，4070 Ti Super的显卡，运行win11是绰绰有余的，但就是经常莫名其妙的卡顿，那资源管理器经常没响应，逼得我愣是学会用powershell命令来管理文件。平常win11刚开机就占用6、7GB的内存，也没设置什么占用资源特别多的开机自启软件，虽然内存够用，但就觉得很坑。之前用win11还经常碰到个问题是我也没干啥，就电脑挂着番茄钟计时，我自己拿着书没动电脑，机箱风扇开始莫名其妙的嗡嗡嗡响，一看后台进程是一些不熟悉的系统进程在占用CPU，也不知道在处理什么。