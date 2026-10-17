import IOKit.hid

enum DeviceScope {
    static let vendor = 5426
    static let product = 555
    static func matching(location: UInt32) -> [String:Any] {
        [kIOHIDVendorIDKey:vendor,kIOHIDProductIDKey:product,kIOHIDLocationIDKey:location,kIOHIDDeviceUsagePageKey:1,kIOHIDDeviceUsageKey:6]
    }
    static func accepts(vendor: Int, product: Int, location: UInt32, selected: UInt32, page: Int, usage: Int) -> Bool {
        selected != 0 && vendor == self.vendor && product == self.product && location == selected && page == 1 && usage == 6
    }
}
