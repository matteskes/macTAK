// CotDetail.swift — one element under an event's <detail> (G3.4).
//
// Ported from the kernel's com.atakmap.coremap.cot.event.CotDetail at the
// pin: a name, attributes, and either inner text or children. Unlike the
// kernel, which keeps attributes in a HashMap, this keeps them in the order
// they were set, so what the app sends reads the same every time.

public struct CotDetail: Sendable, Equatable {
    public struct Attribute: Sendable, Equatable {
        public var name: String
        public var value: String
    }

    public var name: String
    public private(set) var attributes: [Attribute] = []
    public var children: [CotDetail] = []
    /// Text of a leaf element. The kernel writes it in place of children.
    public var innerText: String?

    public init(_ name: String) {
        self.name = name
    }

    public subscript(attribute: String) -> String? {
        get { attributes.first { $0.name == attribute }?.value }
        set {
            guard let value = newValue else {
                attributes.removeAll { $0.name == attribute }
                return
            }
            if let i = attributes.firstIndex(where: { $0.name == attribute }) {
                attributes[i].value = value
            } else {
                attributes.append(Attribute(name: attribute, value: value))
            }
        }
    }

    /// The first child with this name.
    public func child(_ name: String) -> CotDetail? {
        children.first { $0.name == name }
    }

    public mutating func add(_ child: CotDetail) {
        children.append(child)
    }

    func write(to out: inout String) {
        out += "<" + name
        for a in attributes {
            out += " \(a.name)='\(Cot.escape(a.value))'"
        }
        if let innerText {
            out += ">" + Cot.escape(innerText) + "</\(name)>"
        } else if children.isEmpty {
            out += "/>"
        } else {
            out += ">"
            for c in children { c.write(to: &out) }
            out += "</\(name)>"
        }
    }
}
