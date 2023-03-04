import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

enum OptionSetMacroDiagnostic {
  case requiresStruct
  case requiresStringLiteral(String)
  case requiresOptionsEnum(String)
  case requiresOptionsEnumRawType
}

extension OptionSetMacroDiagnostic: DiagnosticMessage {
  func diagnose<Node: SyntaxProtocol>(at node: Node) -> Diagnostic {
    Diagnostic(node: Syntax(node), message: self)
  }

  var message: String {
    switch self {
    case .requiresStruct:
      return "'OptionSet' macro can only be applied to a struct"

    case .requiresStringLiteral(let name):
      return "'OptionSet' macro argument \(name) must be a string literal"

    case .requiresOptionsEnum(let name):
      return "'OptionSet' macro requires nested options enum '\(name)'"

    case .requiresOptionsEnumRawType:
      return "'OptionSet' macro requires a raw type"
    }
  }

  var severity: DiagnosticSeverity { .error }

  var diagnosticID: MessageID {
    MessageID(domain: "Swift", id: "OptionSet.\(self)")
  }
}


/// The label used for the OptionSet macro argument that provides the name of
/// the nested options enum.
private let optionsEnumNameArgumentLabel = "optionsName"

/// The default name used for the nested "Options" enum. This should
/// eventually be overridable.
private let defaultOptionsEnumName = "Options"

extension TupleExprElementListSyntax {
  /// Retrieve the first element with the given label.
  func first(labeled name: String) -> Element? {
    return first { element in
      if let label = element.label, label.text == name {
        return true
      }

      return false
    }
  }
}

public struct OptionSetMacro {
  /// Decodes the arguments to the macro expansion.
  ///
  /// - Returns: the important arguments used by the various roles of this
  /// macro inhabits, or nil if an error occurred.
  static func decodeExpansion<
    Decl: DeclGroupSyntax,
    Context: MacroExpansionContext
  >(
    of attribute: AttributeSyntax,
    attachedTo decl: Decl,
    in context: Context
  ) -> (StructDeclSyntax, EnumDeclSyntax, TypeSyntax)? {
    // Determine the name of the options enum.
    let optionsEnumName: String
    if case let .argumentList(arguments) = attribute.argument,
       let optionEnumNameArg = arguments.first(labeled: optionsEnumNameArgumentLabel) {
      // We have a options name; make sure it is a string literal.
      guard let stringLiteral = optionEnumNameArg.expression.as(StringLiteralExprSyntax.self),
         stringLiteral.segments.count == 1,
          case let .stringSegment(optionsEnumNameString)? = stringLiteral.segments.first else {
        context.diagnose(OptionSetMacroDiagnostic.requiresStringLiteral(optionsEnumNameArgumentLabel).diagnose(at: optionEnumNameArg.expression))
        return nil
      }

      optionsEnumName = optionsEnumNameString.content.text
    } else {
      optionsEnumName = defaultOptionsEnumName
    }

    // Only apply to structs.
    guard let structDecl = decl.as(StructDeclSyntax.self) else {
      context.diagnose(OptionSetMacroDiagnostic.requiresStruct.diagnose(at: decl))
      return nil
    }

    // Find the option enum within the struct.
    let optionsEnums: [EnumDeclSyntax] = decl.members.members.compactMap({ member in
      if let enumDecl = member.decl.as(EnumDeclSyntax.self),
         enumDecl.identifier.text == optionsEnumName {
        return enumDecl
      }

      return nil
    })

    guard let optionsEnum = optionsEnums.first else {
      context.diagnose(OptionSetMacroDiagnostic.requiresOptionsEnum(optionsEnumName).diagnose(at: decl))
      return nil
    }

    // Retrieve the raw type from the attribute.
    guard let genericArgs = attribute.attributeName.as(SimpleTypeIdentifierSyntax.self)?.genericArgumentClause,
          let rawType = genericArgs.arguments.first?.argumentType else {
      context.diagnose(OptionSetMacroDiagnostic.requiresOptionsEnumRawType.diagnose(at: attribute))
      return nil
    }


    return (structDecl, optionsEnum, rawType)
  }
}

extension OptionSetMacro: ConformanceMacro {
  public static func expansion<
    Decl: DeclGroupSyntax,
    Context: MacroExpansionContext
  >(
    of attribute: AttributeSyntax,
    providingConformancesOf decl: Decl,
    in context: Context
  ) throws -> [(TypeSyntax, GenericWhereClauseSyntax?)] {
    // Decode the expansion arguments.
    guard let (structDecl, _, _) = decodeExpansion(of: attribute, attachedTo: decl, in: context) else {
      return []
    }

    // If there is an explicit conformance to OptionSet already, don't add one.
    if let inheritedTypes = structDecl.inheritanceClause?.inheritedTypeCollection,
       inheritedTypes.contains(where: { inherited in inherited.typeName.trimmedDescription == "OptionSet" }) {
      return []
    }

    return [("OptionSet", nil)]
  }
}

extension OptionSetMacro: MemberMacro {
  public static func expansion<
    Decl: DeclGroupSyntax,
    Context: MacroExpansionContext
  >(
    of attribute: AttributeSyntax,
    providingMembersOf decl: Decl,
    in context: Context
  ) throws -> [DeclSyntax] {
    // Decode the expansion arguments.
    guard let (_, optionsEnum, rawType) = decodeExpansion(of: attribute, attachedTo: decl, in: context) else {
      return []
    }

    // Find all of the case elements.
    let caseElements: [EnumCaseElementSyntax] = optionsEnum.members.members.flatMap { member in
      guard let caseDecl = member.decl.as(EnumCaseDeclSyntax.self) else {
        return Array<EnumCaseElementSyntax>()
      }

      return Array(caseDecl.elements)
    }

    // Dig out the access control keyword we need.
    let access = decl.modifiers?.first(where: \.isNeededAccessLevelModifier)

    let staticVars = caseElements.map { (element) -> DeclSyntax in
      """
      \(access) static let \(element.identifier): Self =
        Self(rawValue: 1 << \(optionsEnum.identifier).\(element.identifier).rawValue)
      """
    }

    return [
      "\(access)typealias RawValue = \(rawType)",
      "\(access)var rawValue: RawValue",
      "\(access)init() { self.rawValue = 0 }",
      "\(access)init(rawValue: RawValue) { self.rawValue = rawValue }",
    ] + staticVars
  }
}

extension DeclModifierSyntax {
  var isNeededAccessLevelModifier: Bool {
    switch self.name.tokenKind {
    case .keyword(.public): return true
    default: return false
    }
  }
}

extension SyntaxStringInterpolation {
  // It would be nice for SwiftSyntaxBuilder to provide this out-of-the-box.
  mutating func appendInterpolation<Node: SyntaxProtocol>(_ node: Node?) {
    if let node = node {
      appendInterpolation(node)
    }
  }
}
