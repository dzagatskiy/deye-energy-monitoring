import AppIntents
import EnergyCore
import WidgetKit

/// An inverter as a choice in "Edit Widget" (ADR 0001).
struct InverterEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Інвертор"
    static let defaultQuery = InverterEntityQuery()

    let id: String
    let name: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
    }

    init(_ descriptor: InverterDescriptor, profile: InverterProfile?) {
        id = descriptor.id.rawValue
        name = profile?.customName ?? descriptor.displayName
        subtitle = "SN …\(descriptor.id.rawValue.suffix(4))" + (descriptor.isOnline ? "" : " · офлайн")
    }
}

struct InverterEntityQuery: EntityQuery {
    func entities(for identifiers: [InverterEntity.ID]) async throws -> [InverterEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [InverterEntity] {
        let settings = await AppEnvironment.loadSettings()
        return settings.inverters.map { descriptor in
            InverterEntity(descriptor, profile: settings.profiles.first { $0.id == descriptor.id })
        }
    }

    func defaultResult() async -> InverterEntity? {
        try? await suggestedEntities().first
    }
}

struct SelectInverterIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Інвертор"
    static let description = IntentDescription("Який інвертор показувати у віджеті.")

    @Parameter(title: "Інвертор")
    var inverter: InverterEntity?

    init() {}
}
