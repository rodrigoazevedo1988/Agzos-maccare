import Foundation

/// Valor protegido por trava, para estado compartilhado entre a tarefa de
/// varredura (em segundo plano) e quem a consome.
///
/// `@unchecked Sendable` é correto aqui porque todo acesso ao valor passa por
/// `lock`; não há caminho de leitura ou escrita fora de `withLock`.
public final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    public var current: Value {
        withLock { $0 }
    }
}
