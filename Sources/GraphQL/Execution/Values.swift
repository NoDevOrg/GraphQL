import Foundation
import OrderedCollections

/**
 * Prepares an object map of variableValues of the correct type based on the
 * provided variable definitions and arbitrary input. If the input cannot be
 * parsed to match the variable definitions, a GraphQLError will be thrown.
 */
func getVariableValues(schema: GraphQLSchema, definitionASTs: [VariableDefinition], inputs: [String: Map]) throws -> [String: Map] {
    return try definitionASTs.reduce([:]) { values, defAST in
        var valuesCopy = values
        let varName = defAST.variable.name.value

        valuesCopy[varName] = try getVariableValue(
            schema: schema,
            definitionAST: defAST,
            input: inputs[varName] ?? .null
        )

        return valuesCopy
    }
}


/**
 * Prepares an object map of argument values given a list of argument
 * definitions and list of argument AST nodes.
 */
func getArgumentValues(argDefs: [GraphQLArgumentDefinition], argASTs: [Argument]?, variableValues: [String: Map] = [:]) throws -> Map {
    guard let argASTs = argASTs else {
        return [:]
    }

    let argASTMap = argASTs.keyMap({ $0.name.value })

    return try argDefs.reduce([:]) { result, argDef in
        var result = result
        let name = argDef.name
        let argAST = argASTMap[name]
        
        if let argAST = argAST {
            let valueAST = argAST.value

            let value = try valueFromAST(
                valueAST: valueAST,
                type: argDef.type,
                variables: variableValues
            )

            result[name] = value
        } else {
            result[name] = .null
        }

        return result
    }
}


/**
 * Given a variable definition, and any value of input, return a value which
 * adheres to the variable definition, or throw an error.
 */
func getVariableValue(schema: GraphQLSchema, definitionAST: VariableDefinition, input: Map) throws -> Map {
    let type = typeFromAST(schema: schema, inputTypeAST: definitionAST.type)
    let variable = definitionAST.variable

    guard let inputType = type as? GraphQLInputType else {
        throw GraphQLError(
            message:
            "Variable \"$\(variable.name.value)\" expected value of type " +
            "\"\(definitionAST.type)\" which cannot be used as an input type.",
            nodes: [definitionAST]
        )
    }
    
    if input == .undefined {
        if let defaultValue = definitionAST.defaultValue {
            return try valueFromAST(valueAST: defaultValue, type: inputType)
        } else {
            if inputType is GraphQLNonNull {
                throw GraphQLError(message: "Non-nullable type \(inputType) must be provided.")
            } else {
                return .undefined
            }
        }
    }
    
    let errors = try isValidValue(value: input, type: inputType)
    guard errors.isEmpty else {
        let message = !errors.isEmpty ? "\n" + errors.joined(separator: "\n") : ""
        throw GraphQLError(
            message:
            "Variable \"$\(variable.name.value)\" got invalid value " +
            "\(input).\(message)", // TODO: "\(JSON.stringify(input)).\(message)",
            nodes: [definitionAST]
        )
    }
    
    return try coerceValue(value: input, type: inputType)
}

/**
 * Given a type and any value, return a runtime value coerced to match the type.
 */
func coerceValue(value: Map, type: GraphQLInputType) throws -> Map {
    if let nonNull = type as? GraphQLNonNull {
        // Note: we're not checking that the result of coerceValue is non-null.
        // We only call this function after calling isValidValue.
        guard let nonNullType = nonNull.ofType as? GraphQLInputType else {
            throw GraphQLError(message: "NonNull must wrap an input type")
        }
        return try coerceValue(value: value, type: nonNullType)
    }
    
    guard value != .undefined && value != .null else {
        return value
    }

    if let list = type as? GraphQLList {
        guard let itemType = list.ofType as? GraphQLInputType else {
            throw GraphQLError(message: "Input list must wrap an input type")
        }

        if case .array(let value) = value {
            let coercedValues = try value.map { item in
                try coerceValue(value: item, type: itemType)
            }
            return .array(coercedValues)
        }
        
        // Convert solitary value into single-value array
        return .array([try coerceValue(value: value, type: itemType)])
    }

    if let objectType = type as? GraphQLInputObjectType {
        guard case .dictionary(let value) = value else {
            throw GraphQLError(message: "Must be dictionary to extract to an input type")
        }

        let fields = objectType.fields
        
        var object = OrderedDictionary<String, Map>()
        for (fieldName, field) in fields {
            if let fieldValueMap = value[fieldName], fieldValueMap != .undefined {
                object[fieldName] = try coerceValue(
                    value: fieldValueMap,
                    type: field.type
                )
            } else {
                // If AST doesn't contain field, it is undefined
                if let defaultValue = field.defaultValue {
                    object[fieldName] = defaultValue
                } else {
                    object[fieldName] = .undefined
                }
            }
        }
        return .dictionary(object)
    }
    
    if let leafType = type as? GraphQLLeafType {
        return try leafType.parseValue(value: value)
    }
    
    throw GraphQLError(message: "Must be input type")
}
