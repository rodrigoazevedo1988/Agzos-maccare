import MacCareCore

/// `Foundation` também declara um `Measurement<UnitType: Unit>`. Em um arquivo
/// que importa SwiftUI/Foundation e MacCareCore, `Measurement<String>` resolve
/// para o tipo do Foundation e não compila. Este alias no nível do módulo do
/// app faz o nome apontar para o tipo do núcleo em todos os arquivos do app.
public typealias Measurement<Value: Sendable> = MacCareCore.Measurement<Value>
