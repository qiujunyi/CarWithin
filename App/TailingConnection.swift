// Adapted from xmz28/ninebot_pro: NinebotPro/Networking/TailingConnection.swift
struct TailingDisplayProfile {
    let width: Int
    let height: Int
    let isZeeho: Bool
    let isCFMotoDiagnostic: Bool
    static let tailing43 = TailingDisplayProfile(width: 480, height: 272, isZeeho: false, isCFMotoDiagnostic: false)
    static let zeeho62 = TailingDisplayProfile(width: 1024, height: 480, isZeeho: true, isCFMotoDiagnostic: false)
    // Experimental PXC diagnostic profile. Not evidence of CFMOTO protocol compatibility.
    static let cfmoto150scf = TailingDisplayProfile(width: 1024, height: 512, isZeeho: true, isCFMotoDiagnostic: true)
}

import Foundation

struct TailingPhoneInfo {
    let package: String
    let versionCode: Int
    let model: String
    let systemVersion: String
    let width: Int
    let height: Int
    let rotation: Int

    func display(mode: Int) -> [String: Any] {
        ["displayRotation": mode == 2 ? 0 : rotation,
         "width": mode == 2 ? min(width, height) : width,
         "height": mode == 2 ? max(width, height) : height,
         "enableAccessibility": false, "enableAOAHid": false, "mode": mode]
    }
}

struct TailingPorts {
    let control: UInt16
    let auxiliary: UInt16
    let video: UInt16
    let announcement: UInt16
    static let ios = TailingPorts(control: 10922, auxiliary: 10711, video: 10710, announcement: 10930)
}

/// 台铃 JPEG 和极核 H.264 共用的 PXC 投屏会话。
final class TailingConnection: @unchecked Sendable {
    private let localIP: String
    private let targetIP: String
    private let profile: TailingDisplayProfile
    private let phone: TailingPhoneInfo
    private let ports: TailingPorts
    private let identityProvider: () throws -> TailingIdentity
    private let log: (String) -> Void
    private let condition = NSCondition()
    private var resources: [TailingSocket] = []
    private var timers: [DispatchSourceTimer] = []
    private var closed = false
    private var closeComplete = false
    private var failure: Error?
    private var identity: TailingIdentity?
    private var huid: String?
    private var signedHUID: Data?
    private var video: TailingSocket?
    private var reverseControl: TailingSocket?
    private var sentH264Prefix = false
    private var cfmotoVideoFrameIndex: UInt32 = 0
    private var mediaStarted = false
    private var configured = false
    // Observe which dashboard channels actually connect; these flags do not affect negotiation.
    private var controlConnected = false
    private var auxiliaryConnected = false
    private var isZeeho: Bool { profile.isZeeho }
    private var dashboard: String { profile.isCFMotoDiagnostic ? "春风 150SC-F" : (profile.isZeeho ? "极核" : "台铃") }

    init(localIP: String, targetIP: String, profile: TailingDisplayProfile, phone: TailingPhoneInfo,
         ports: TailingPorts = .ios, identityProvider: @escaping () throws -> TailingIdentity = TailingIdentity.load,
         log: @escaping (String) -> Void) {
        self.localIP = localIP; self.targetIP = targetIP; self.profile = profile; self.phone = phone
        self.ports = ports; self.identityProvider = identityProvider; self.log = log
    }

    func start() throws {
        if profile.isCFMotoDiagnostic {
            log("春风 150SC-F：EasyConn 会话；视频编码 1024×512（仪表请求 1024×515）")
        }
        // EasyConn legacy CFMOTO is independently authenticated by the bike
        // using a session-local RSA-1024 key. MFi/iAP2 authentication is separate
        // and is never touched by the PXC compatibility profile.
        let loaded = profile.isCFMotoDiagnostic
            ? try TailingIdentity.generate(keySizeInBits: 1024)
            : try identityProvider()
        condition.lock(); identity = loaded; condition.unlock()
        if profile.isCFMotoDiagnostic {
            log("春风旧版 EasyConn 兼容身份：PXC RSA-1024（会话临时密钥），supportFunction=0")
        }
        // 先全部监听，再请求仪表反向连接；不使用所有网卡的通配地址。
        var listeners: [(UInt16, TailingSocket)] = []
        for port in [ports.control, ports.auxiliary, ports.video] {
            let server = try tracked(TailingSocket.create())
            try server.listen(localIP: localIP, port: port)
            listeners.append((port, server))
        }
        for (port, server) in listeners {
            DispatchQueue.global(qos: .userInitiated).async { [self] in accept(server, port: port) }
        }
        log("\(dashboard) TCP 已监听 \(localIP):\(ports.control)/\(ports.auxiliary)/\(ports.video)，正在协商")
        let announcement = try tracked(TailingSocket.create())
        defer { announcement.close() }
        try announcement.connect(localIP: localIP, remoteIP: targetIP, port: ports.announcement)
        if profile.isCFMotoDiagnostic {
            // Successful CFDL16 log: EasyConn init 0x10 -> 0x11 on 10930.
            // This differs from a PXC wake probe 0x70000010 (disabled on Android).
            let packet = try TailingProtocol.easyConnInit(
                phoneType: "Android", packageName: "com.lxt.cfmoto")
            try announcement.write(packet)
            log("春风 EasyConn 初始化 TX 10930：0x10")
            let header = try announcement.readExactly(16, timeout: 5)
            guard header.count == 16 else {
                throw TailingError.protocolFailure("春风 EasyConn 初始化回应头不完整")
            }
            let responseCommand = header.uint16LE(0)
            let responseLength = Int(header.uint16LE(4))
            guard responseCommand == 0x11, (16...4096).contains(responseLength) else {
                throw TailingError.protocolFailure("春风 EasyConn 未确认 0x11 初始化")
            }
            if responseLength > 16 {
                _ = try announcement.readExactly(responseLength - 16, timeout: 5)
            }
            log("春风 EasyConn 初始化 RX 10930：0x11，等待仪表回连")
        } else {
            try announcement.write(TailingProtocol.control(0x70000010, payload: TailingProtocol.json([
                "phoneType": "iOS", "packageName": phone.package
            ])))
            let reply = try TailingProtocol.readControl { try announcement.readExactly($0, timeout: 3) }
            guard reply.command == 0x70000011,
                  try TailingProtocol.object(reply.payload)["status"] as? Bool == true else {
                throw TailingError.protocolFailure("仪表未接受 PXC 投屏请求")
            }
        }
        let deadline = Date().addingTimeInterval(20)
        condition.lock()
        defer { condition.unlock() }
        while !closed && failure == nil && (signedHUID == nil || video == nil || !mediaStarted || (isZeeho && !profile.isCFMotoDiagnostic && reverseControl == nil)) {
            if !condition.wait(until: deadline) {
                let state = profile.isCFMotoDiagnostic ? "；" + diagnosticStateLocked() : ""
                throw TailingError.timeout("媒体会话未就绪" + state + "，请退出官方投屏并重新开启仪表投屏")
            }
        }
        try checkLocked()
        log("\(dashboard) 媒体协商完成，等待仪表逐帧请求")
    }

    @discardableResult
    func sendJPEG(_ jpeg: Data) throws -> (pullWait: TimeInterval, writeTime: TimeInterval) {
        let (socket, pullWait) = try readFrameRequest()
        let packet = try TailingProtocol.jpeg(jpeg)
        let writeStarted = ProcessInfo.processInfo.systemUptime
        do {
            try socket.write(packet)
        } catch {
            throw terminalError(or: TailingError.channel("发送 JPEG", error))
        }
        return (pullWait, ProcessInfo.processInfo.systemUptime - writeStarted)
    }

    func waitForH264Request() throws {
        _ = try readFrameRequest()
    }

    // 视频请求与发送由同一个会话任务顺序执行。
    func sendH264(_ accessUnit: Data) throws {
        let socket = try videoSocket()
        let packet: Data
        if profile.isCFMotoDiagnostic {
            packet = try TailingProtocol.h264Indexed(accessUnit, frameIndex: cfmotoVideoFrameIndex)
            cfmotoVideoFrameIndex = (cfmotoVideoFrameIndex &+ 1) & 0x7fff_ffff
        } else {
            packet = try TailingProtocol.h264(accessUnit, includePrefix: !sentH264Prefix)
        }
        do {
            try socket.write(packet)
            sentH264Prefix = true
        } catch {
            throw terminalError(or: TailingError.channel("发送 H.264", error))
        }
    }

    private var resumeKeyframePending = false

    func consumeResumeKeyframe() -> Bool {
        condition.lock(); defer { condition.unlock() }
        let pending = resumeKeyframePending
        resumeKeyframePending = false
        return pending
    }

    private func videoSocket() throws -> TailingSocket {
        condition.lock()
        defer { condition.unlock() }
        try checkLocked()
        while profile.isCFMotoDiagnostic && video == nil {
            condition.wait()
            try checkLocked()
        }
        guard let video else { throw TailingError.closed }
        return video
    }

    private func readFrameRequest() throws -> (TailingSocket, TimeInterval) {
        let pullStarted = ProcessInfo.processInfo.systemUptime
        while true {
            let socket = try videoSocket()
            let request: TailingProtocol.Auxiliary
            do {
                // BACK may leave the video socket idle indefinitely. Only the first
                // byte waits indefinitely; partial headers/payloads retain a deadline.
                var readingHeader = true
                request = try TailingProtocol.readAuxiliary { count in
                    defer { readingHeader = false }
                    return try socket.readExactly(count, timeout: 5,
                        waitForFirstByte: profile.isCFMotoDiagnostic && readingHeader)
                }
            } catch {
                if profile.isCFMotoDiagnostic, let transport = error as? TailingError,
                   case .closed = transport {
                    condition.lock()
                    let recover = !closed && failure == nil
                    if recover && video === socket { video = nil }
                    if recover { resources.removeAll { $0 === socket } }
                    condition.unlock()
                    if recover {
                        socket.close()
                        log("春风视频通道已退出，保留会话等待仪表回连（SET）")
                        continue
                    }
                }
                throw terminalError(or: TailingError.channel("等待视频拉帧请求", error))
            }
            let pullWait = ProcessInfo.processInfo.systemUptime - pullStarted
            guard request.command == 0x72, request.payload.isEmpty else {
                throw TailingError.protocolFailure(String(format: "视频通道收到 0x%04x（%d 字节），预期空载荷 0x72",
                                                         Int(request.command), request.payload.count))
            }
            if profile.isCFMotoDiagnostic && pullWait >= 1 {
                log("春风仪表恢复取帧，继续投屏")
            }
            return (socket, pullWait)
        }
    }

    /// True only when the session was deliberately closed without a transport failure.
    /// Lets presentation code avoid reporting the expected socket wake-up as an error.
    var isClosingNormally: Bool {
        condition.lock()
        defer { condition.unlock() }
        return closed && failure == nil
    }

    func checkHealth() throws {
        condition.lock()
        defer { condition.unlock() }
        try checkLocked()
    }

    private func terminalError(or fallback: Error) -> Error {
        do { try checkHealth() } catch { return error }
        return fallback
    }

    func close() {
        condition.lock()
        if closed {
            while !closeComplete { condition.wait() }
            condition.unlock()
            return
        }
        closed = true
        let sockets = resources
        let pendingTimers = timers
        let reverse = failure == nil ? reverseControl : nil
        resources.removeAll(); timers.removeAll()
        condition.broadcast()
        condition.unlock()
        pendingTimers.forEach { $0.cancel() }
        if let reverse {
            do {
                try sendMirrorControl(reverse, start: false, identifier: UInt32.max, timeout: 0.25)
                log("极核已发送停止投屏通知")
            } catch {
                log("极核停止通知发送失败：\(error.localizedDescription)")
            }
        }
        sockets.forEach { $0.close() }
        condition.lock()
        closeComplete = true
        condition.broadcast()
        condition.unlock()
    }

    private func tracked(_ socket: TailingSocket) throws -> TailingSocket {
        condition.lock()
        defer { condition.unlock() }
        if closed { socket.close(); throw TailingError.closed }
        resources.append(socket)
        return socket
    }

    /// Call with condition locked. Never includes HUID, certificates, tokens or QR credentials.
    private func diagnosticStateLocked() -> String {
        "身份=\(signedHUID == nil ? "未回应" : "已回应")；控制=\(controlConnected ? "已连接" : "未连接")；媒体控制=\(auxiliaryConnected ? "已连接" : "未连接")；媒体配置=\(configured ? "完成" : "未完成")；媒体启动=\(mediaStarted ? "完成" : "未完成")；视频=\(video == nil ? "未连接" : "已连接")；媒体端口=\(ports.auxiliary)/\(ports.video)；镜像控制=\(profile.isCFMotoDiagnostic ? "仪表自主启动" : (reverseControl == nil ? "未就绪" : "已发送"))"
    }

    private func accept(_ server: TailingSocket, port: UInt16) {
        do {
            while true {
                let socket = try tracked(server.accept(remoteIP: targetIP))
                if isZeeho { log("\(dashboard) TCP\(port) 已回连") }
                condition.lock()
                if port == ports.control { controlConnected = true }
                if port == ports.auxiliary { auxiliaryConnected = true }
                condition.broadcast()
                condition.unlock()
                if port == ports.video {
                    condition.lock()
                    if !closed && (video == nil || profile.isCFMotoDiagnostic) {
                        let previous = video
                        video = socket
                        if profile.isCFMotoDiagnostic { resumeKeyframePending = true }
                        if let previous { resources.removeAll { $0 === previous } }
                        condition.broadcast()
                        condition.unlock()
                        previous?.close()
                    } else {
                        condition.unlock()
                        socket.close()
                    }
                } else {
                    DispatchQueue.global(qos: .userInitiated).async { [self] in
                        do {
                            if port == ports.auxiliary { try auxiliary(socket) }
                            else { try control(socket) }
                        } catch {
                            let channel = port == ports.auxiliary ? "媒体控制 TCP\(port)" : "会话控制 TCP\(port)"
                            fail(TailingError.channel(channel, error))
                        }
                    }
                }
            }
        } catch { fail(error) }
    }

    private func control(_ socket: TailingSocket) throws {
        var reverseStarted = false
        var heartbeatStarted = false
        var reportedUnsupported = false
        while true {
            // 连接在两条完整消息之间可以静默，收到半条消息后仍限制读取时间。
            var readingHeader = true
            let request = try TailingProtocol.readControl { count in
                defer { readingHeader = false }
                return try socket.readExactly(count, waitForFirstByte: readingHeader)
            }
            if profile.isCFMotoDiagnostic && request.command != 0x70000000 {
                log(String(format: "PXC RX %d: cmd=0x%08x, id=%u, bytes=%d",
                           Int(ports.control), request.command, request.identifier, request.payload.count))
            }
            var payload = Data()
            switch request.command {
            case 0x10000, 0x20000, 0x10740, 0x10040, 0x70000000:
                break
            case 0x10690 where isZeeho, 0x10780 where isZeeho:
                // 极核上报 FTP 速率和运行日志，投屏会话只确认收到。
                break
            case 0x103e0 where profile.isCFMotoDiagnostic:
                // CFMOTO CHECK_SN: acknowledging the request is not enough. The bike
                // expects a separate CHECK_SN_RESULT before it may open 10921/10920.
                // Don't log the serial number or client-set token.
                let requestInfo = (try? TailingProtocol.object(request.payload)) ?? [:]
                let serial = requestInfo["sn"] as? String ?? ""
                let clientSet = requestInfo["client_set"] as? String ?? "easy_conn"
                try replyControl(socket, request, payload: Data())
                try sendControl(socket, command: 0x201c0, identifier: 0,
                                object: ["isOk": true, "errCode": 0, "errMsg": "",
                                         "id": serial, "client_set": clientSet])
                log("春风 PXC 已确认 CHECK_SN 并发送 0x201c0 结果（序列号不写入日志）")
                continue
            case 0x103e0 where isZeeho:
                // 0x103e1 是收件确认。序列号校验结果使用独立命令。
                log("极核收到序列号校验请求，等待仪表继续媒体协商")
            case 0x10010:
                let object = try TailingProtocol.object(request.payload)
                guard let name = object["HUName"] as? String, !name.isEmpty, name.utf8.count <= 128,
                      let huid = object["HUID"] as? String, !huid.isEmpty else {
                    throw TailingError.protocolFailure("仪表设备资料不完整")
                }
                if isZeeho && name == "TL-DASH-V2" {
                    throw TailingError.protocolFailure("目标报告台铃 TL-DASH-V2，请检查仪表配置")
                }
                if !isZeeho && name != "TL-DASH-V2" {
                    throw TailingError.protocolFailure("目标能力不是已支持的 TL-DASH-V2")
                }
                condition.lock(); let identity = self.identity; condition.unlock()
                guard let identity else { throw TailingError.closed }
                if profile.isCFMotoDiagnostic {
                    func field(_ key: String) -> String {
                        guard let value = object[key] else { return "未提供" }
                        if let n = value as? NSNumber { return n.stringValue }
                        return "已提供"
                    }
                    // Show only harmless firmware metadata; never log HUID, pairing
                    // serial number, Wi-Fi credentials or user-defined identifiers.
                    func version(_ key: String) -> String {
                        guard let value = object[key] as? String else { return "未提供" }
                        return String(value.prefix(24)).replacingOccurrences(of: "\n", with: " ")
                    }
                    log("春风仪表协议能力：sdkVersion=\(version("sdkVersion"))，pxcVersion=\(version("pxcVersion"))，mirrorMode=\(field("mirrorMode"))，productType=\(field("productType"))，screenType=\(field("screenType"))，supportScreenMirroring=\(field("supportScreenMirroring"))，enableSockServerAuth=\(field("enableSockServerAuth"))")
                }
                let signature = try identity.sign(huid)
                if profile.isCFMotoDiagnostic {
                    // Compare with the documented legacy CFDL16 / modelId 37416
                    // EasyConn client-info profile. Do not send the Zeeho-only
                    // mirrorRequestReconnect field or advertise unsupported flags.
                    payload = try TailingProtocol.json([
                        "pxcVersion": "1.0.2", "phoneUUID": identity.phoneID,
                        "phoneBrand": "Apple", "phoneModel": "iPhone",
                        "phoneOsVersion": "35", "phoneOs": "Android",
                        "package": "com.cfmoto.cfmotointernational",
                        "versionCode": 126, "token": 0,
                        "pubkey": try identity.publicKey().base64EncodedString(),
                        "encryptedHUID": signature.base64EncodedString(),
                        "bluetoothName": "CarWithin", "supportH264IFrame": true,
                        "supportFunction": 0, "supportSyncCorrectTime": false,
                        "appVersionFingerPrint": "carwithin-cfmoto-test"
                    ])
                } else {
                    payload = try TailingProtocol.json([
                        "pxcVersion": "1.0.2", "phoneUUID": identity.phoneID,
                        "phoneBrand": "iPhone", "phoneModel": phone.model,
                        "phoneOsVersion": phone.systemVersion, "phoneOs": "iOS",
                        "package": phone.package, "versionCode": phone.versionCode, "token": 0,
                        "pubkey": try identity.publicKey().base64EncodedString(),
                        "encryptedHUID": signature.base64EncodedString(), "bluetoothName": "",
                        "supportH264IFrame": isZeeho, "supportFunction": 128, "mirrorRequestReconnect": true
                    ])
                }
                try replyControl(socket, request, payload: payload)
                condition.lock()
                self.huid = huid; signedHUID = signature; condition.broadcast()
                condition.unlock()
                log("仪表报告 HUName=\(name.debugDescription)，已回应本机 PXC RSA\(profile.isCFMotoDiagnostic ? 1024 : 2048) 身份")
                continue
            case 0x10600 where profile.isCFMotoDiagnostic:
                // CFDL16 EasyConn HU_TIME_SYNC is a binary body with a
                // 29-byte yyyy-MM-dd HH:mm:ss.SSS000000 timestamp at offset 16.
                // Echo a valid dash clock, never send an empty ACK that resets
                // some dashboards to 1970. See MotoLink control.ts.
                var timeBody = request.payload
                let stampLength = 29
                let stampOffset = 16
                var invalidClock = timeBody.count < stampOffset + stampLength
                if !invalidClock {
                    let bytes = Data(timeBody[stampOffset..<(stampOffset + stampLength)])
                    let stamp = String(decoding: bytes, as: UTF8.self)
                    let year = Int(stamp.prefix(4)) ?? 0
                    invalidClock = year < 2000 || stamp.count != stampLength ||
                        !stamp.contains("-") || !stamp.contains(":")
                }
                if invalidClock {
                    if timeBody.count < stampOffset + stampLength {
                        timeBody.append(Data(repeating: 0, count: stampOffset + stampLength - timeBody.count))
                    }
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
                    let corrected = formatter.string(from: Date()) + "000000"
                    timeBody.replaceSubrange(stampOffset..<(stampOffset + stampLength),
                                             with: corrected.utf8)
                }
                try replyControl(socket, request, payload: timeBody)
                log("春风 PXC 已回应 0x10600 时间同步（\(invalidClock ? "修正仪表时间" : "回显仪表时间")）")
                continue
            case 0x10450:
                let time = Int64(Date().timeIntervalSince1970 * 1_000)
                payload = try TailingProtocol.json([
                    "time": time, "currentTime": time + Int64(TimeZone.current.secondsFromGMT()) * 1_000,
                    "currentTimeZone": TimeZone.current.identifier
                ])
            case 0x80000010:
                // 与安卓修正一致：这是“不支持”回应，不是请求。可选状态不被支持时，
                // 仍等待身份、媒体配置与启动三个必要条件，不触发额外状态发送。
                if !reportedUnsupported {
                    reportedUnsupported = true
                    log(String(format: "仪表报告不支持控制消息（id=%u）；继续等待媒体协商", request.identifier))
                }
                continue
            case 0x201c1 where profile.isCFMotoDiagnostic:
                log("春风 PXC 仪表已确认 0x201c0 CHECK_SN_RESULT，等待媒体通道")
                continue
            case 0x20021, 0x20031, 0x204c1, 0x20491, 0x20051, 0x20591, 0x205a1, 0x201c1, 0x70000001:
                continue // 回应不再回应，避免往返循环。
            default:
                if profile.isCFMotoDiagnostic {
                    if request.command & 1 == 0 {
                        // Known MotoPlay variants send notifications that must receive
                        // cmd+1 ACK before media sockets are established. Keep this
                        // fallback only in the experimental CFMOTO profile.
                        log(String(format: "春风未知 PXC 请求 0x%08x：发送空 ACK", request.command))
                        try replyControl(socket, request, payload: Data())
                    } else {
                        log(String(format: "春风未知 PXC 回应 0x%08x：不重复 ACK", request.command))
                    }
                    continue
                }
                throw TailingError.protocolFailure(String(format: "未支持的协商命令 0x%08x", request.command))
            }
            try replyControl(socket, request, payload: payload)
            if !profile.isCFMotoDiagnostic && !heartbeatStarted &&
                (request.command == 0x10000 || request.command == 0x20000) {
                // Some MotoPlay HUs require heartbeat on both independent
                // CAR_CTRL and CAR_DATA sockets, not only the second socket.
                heartbeatStarted = true
                startHeartbeat(socket)
                log("春风 PXC 已开始通道保活，等待仪表后续协商")
            }
            if request.command == 0x20000 && !reverseStarted {
                reverseStarted = true
                if profile.isCFMotoDiagnostic {
                    // MotoPlay implementations do not require the Zeeho-specific
                    // 0x205a0/0x20590 commands (rejected by this 150SC-F firmware).
                    // Let the dashboard initiate 10921/10920 on its own.
                    log("春风 PXC CAR_DATA 已确认：不发送不支持的极核指令，等待媒体端口回连")
                } else {
                    try sendControl(socket, command: 0x204c0, identifier: 1, object: ["state": 0, "msg": ""])
                    try sendControl(socket, command: 0x20020, identifier: 2, object: phone.display(mode: 2))
                    try sendControl(socket, command: 0x20030, identifier: 3, object: phone.display(mode: 1))
                    try socket.write(TailingProtocol.control(0x20050, identifier: 4))
                    try sendControl(socket, command: 0x205a0, identifier: 5, object: ["isMaskVisible": false])
                    if isZeeho { try startZeehoMirror(socket) }
                    startHeartbeat(socket)
                }
            }
        }
    }

    private func replyControl(_ socket: TailingSocket, _ request: TailingProtocol.Control, payload: Data) throws {
        let command = request.command &+ 1
        try socket.write(TailingProtocol.control(command, identifier: request.identifier, payload: payload))
        if profile.isCFMotoDiagnostic {
            log(String(format: "PXC TX %d: cmd=0x%08x, id=%u, bytes=%d",
                       Int(ports.control), command, request.identifier, payload.count))
        }
    }

    private func sendControl(_ socket: TailingSocket, command: UInt32, identifier: UInt32,
                             object: [String: Any]) throws {
        let payload = try TailingProtocol.json(object)
        try socket.write(TailingProtocol.control(command, identifier: identifier, payload: payload))
        if profile.isCFMotoDiagnostic {
            log(String(format: "PXC TX %d: cmd=0x%08x, id=%u, bytes=%d",
                       Int(ports.control), command, identifier, payload.count))
        }
    }

    private func startZeehoMirror(_ socket: TailingSocket) throws {
        condition.lock()
        defer { condition.unlock() }
        try checkLocked()
        guard reverseControl == nil else { return }
        try sendMirrorControl(socket, start: true, identifier: 6, timeout: 0.25)
        reverseControl = socket
        log("\(dashboard) 已发送 0x20590 开始投屏通知（尚未确认媒体通道）")
        condition.broadcast()
    }

    private func sendMirrorControl(_ socket: TailingSocket, start: Bool, identifier: UInt32,
                                   timeout: TimeInterval) throws {
        let payload = try TailingProtocol.json(["control": start ? 1 : 0])
        try socket.write(TailingProtocol.control(0x20590, identifier: identifier, payload: payload), timeout: timeout)
    }

    private func startHeartbeat(_ socket: TailingSocket) {
        // iOS 成功抓包中同屏状态只在启动时发送，反向连接随后用 0x70000000 保活。
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.hanlin.ninebotpro.tailing.status"))
        var identifier: UInt32 = isZeeho ? 7 : 6
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self, weak socket] in
            guard let self, let socket else { return }
            do {
                try socket.write(TailingProtocol.control(0x70000000, identifier: identifier))
                identifier &+= 1
            } catch { self.fail(TailingError.channel("发送会话保活", error)) }
        }
        condition.lock()
        let stopped = closed
        if !stopped { timers.append(timer) }
        // 即便已经停止，也先激活再取消，避免释放未激活的 dispatch source。
        timer.resume()
        if stopped { timer.cancel() }
        condition.unlock()
    }

    private func auxiliary(_ socket: TailingSocket) throws {
        while true {
            // 此通道可能长时间空闲，停止通过 shutdown 唤醒。
            var readingHeader = true
            let request = try TailingProtocol.readAuxiliary { count in
                defer { readingHeader = false }
                return try socket.readExactly(count, waitForFirstByte: readingHeader)
            }
            if profile.isCFMotoDiagnostic {
                log(String(format: "PXC RX %d: cmd=0x%04x, bytes=%d",
                           Int(ports.auxiliary), request.command, request.payload.count))
            }
            var payload = Data()
            let response: UInt16
            switch request.command {
            case 0x10:
                let minConfigLength = profile.isCFMotoDiagnostic ? 12 : 32
                guard request.payload.count >= minConfigLength else {
                    throw TailingError.protocolFailure("媒体配置载荷不足 \(minConfigLength) 字节")
                }
                let width = request.payload.uint16LE(0)
                let height = request.payload.uint16LE(2)
                if profile.isCFMotoDiagnostic {
                    log("春风媒体配置请求：报告尺寸 \(width)×\(height)；视频编码保持 \(profile.width)×\(profile.height)")
                }
                let validDimensions = profile.isCFMotoDiagnostic
                    ? (320...1920).contains(Int(width)) && (240...1080).contains(Int(height))
                    : (isZeeho ? width == 1024 && (height == 480 || height == 488)
                       : width == 480 && height == 272)
                guard validDimensions else {
                    throw TailingError.protocolFailure("仪表媒体尺寸 \(width)×\(height) 与 \(dashboard) 配置不符")
                }
                if profile.isCFMotoDiagnostic {
                    // Standard EasyConn MediaProject capture configuration needs
                    // only the dimensions, fps and requested codec. The original
                    // Zeeho identity-echo extension is not present on every bike.
                    let requestedEncoder = request.payload.uint32LE(8)
                    if request.payload.count > 32,
                       let signature = signedHUID,
                       let echoed = Data(base64Encoded: request.payload.dropFirst(32),
                                         options: .ignoreUnknownCharacters) {
                        log(echoed == signature ? "春风媒体身份回显匹配" : "春风媒体配置携带非匹配扩展，继续兼容协商")
                    }
                    payload.appendLE(UInt32(2)) // H.264
                    let alignedWidth = width & ~UInt16(15)
                    let alignedHeight = height & ~UInt16(15)
                    payload.appendLE(alignedWidth)
                    payload.appendLE(alignedHeight)
                    payload.append(request.payload.count > 29 ? request.payload[29] : UInt8(0))
                    log("春风媒体配置：请求编码器=\(requestedEncoder)，回报 H.264 / \(alignedWidth)×\(alignedHeight)，扩展位=\(payload[8])")
                } else {
                    let deadline = Date().addingTimeInterval(5)
                    condition.lock()
                    while signedHUID == nil && !closed {
                        if !condition.wait(until: deadline) { break }
                    }
                    let signature = signedHUID, huid = self.huid, identity = self.identity
                    condition.unlock()
                    guard let signature, let huid, let identity,
                          let echoed = Data(base64Encoded: request.payload.dropFirst(32), options: .ignoreUnknownCharacters),
                          echoed == signature else { throw TailingError.protocolFailure("媒体身份回显不匹配") }
                    try identity.verify(echoed, huid: huid)
                    payload.appendLE(UInt32(isZeeho ? 2 : 1))
                    payload.appendLE(UInt16(profile.width))
                    payload.appendLE(UInt16(profile.height))
                    log("媒体身份回显校验通过，仪表报告 \(width)×\(height)，回应 \(isZeeho ? "H.264" : "JPEG") / \(profile.width)×\(profile.height)")
                }
                response = 0x11
                condition.lock(); configured = true; condition.broadcast(); condition.unlock()
            case 0x70:
                condition.lock(); let ready = configured; condition.unlock()
                guard ready else { throw TailingError.protocolFailure("仪表在配置完成前请求媒体启动") }
                try socket.write(TailingProtocol.auxiliary(0x71, token: request.token))
                condition.lock(); mediaStarted = true; condition.broadcast(); condition.unlock()
                if profile.isCFMotoDiagnostic { log("PXC TX 媒体控制：0x71 启动确认") }
                continue
            case 0x40: response = 0x41
            case 0x30:
                response = 0x31; payload.appendLE(UInt32(5002)); payload.appendLE(UInt32(1))
            case 0x60:
                response = 0x61
                payload = try TailingProtocol.json(profile.isCFMotoDiagnostic ? ["state": 0] : ["supportFunction": 0])
            case 0x80 where profile.isCFMotoDiagnostic:
                // Some MotoPlay firmwares request START_H264 separately.
                response = 0x81
            case 0x20: continue // 不执行反控触摸。
            default:
                response = 0x7f02
                log(String(format: "媒体控制通道暂不支持 0x%04x", request.command))
            }
            try socket.write(TailingProtocol.auxiliary(response, token: request.token, payload: payload))
            if profile.isCFMotoDiagnostic {
                log(String(format: "PXC TX %d: cmd=0x%04x, bytes=%d",
                           Int(ports.auxiliary), response, payload.count))
            }
        }
    }

    private func checkLocked() throws {
        if let failure { throw failure }
        if closed { throw TailingError.closed }
    }

    private func fail(_ error: Error) {
        condition.lock()
        let shouldFail = !closed && failure == nil
        if shouldFail { failure = error }
        condition.unlock()
        if shouldFail { close() }
    }
}
