import ServiceManagement

protocol LaunchAtLoginManaging {
    var status: SMAppService.Status { get }
    func setEnabled(_ enabled: Bool) throws
}

struct SystemLaunchAtLoginManager: LaunchAtLoginManaging {
    var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        switch enabled {
        case true:
            if service.status != .enabled {
                try service.register()
            }
        case false:
            if service.status == .enabled {
                try service.unregister()
            }
        }
    }
}
