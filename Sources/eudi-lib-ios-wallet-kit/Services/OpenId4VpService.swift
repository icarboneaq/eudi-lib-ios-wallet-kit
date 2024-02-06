/*
Copyright (c) 2023 European Commission

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Created on 04/10/2023 
*/

import Foundation
import SwiftCBOR
import MdocDataModel18013
import MdocSecurity18013
import MdocDataTransfer18013
import SiopOpenID4VP
import JOSESwift
import Logging
#if canImport(UIKit)
import UIKit
import SafariServices
#endif
/// Implements remote attestation presentation to online verifier

/// Implementation is based on the OpenID4VP – Draft 18 specification
public class OpenId4VpService: PresentationService {
	public var status: TransferStatus = .initialized
	var openid4VPlink: String
	var docs: [DeviceResponse]!
	var iaca: [SecCertificate]!
	var dauthMethod: DeviceAuthMethod
	var devicePrivateKey: CoseKeyPrivate!
	var logger = Logger(label: "OpenId4VpService")
	var presentationDefinition: PresentationDefinition?
	var resolvedRequestData: ResolvedRequestData?
	var siopOpenId4Vp: SiopOpenID4VP!
	var openId4VpVerifierApiUri: String?
	var readerAuthValidated: Bool = false
	var readerCertificateIssuer: String?
	var readerCertificateValidationMessage: String?
	public var flow: FlowType

	public init(parameters: [String: Any], qrCode: Data, openId4VpVerifierApiUri: String?) throws {
		self.flow = .openid4vp(qrCode: qrCode)
		guard let (docs, devicePrivateKey, iaca, dauthMethod) = MdocHelpers.initializeData(parameters: parameters) else {
			throw PresentationSession.makeError(str: "MDOC_DATA_NOT_AVAILABLE")
		}
		self.docs = docs; self.devicePrivateKey = devicePrivateKey; self.iaca = iaca; self.dauthMethod = dauthMethod
		guard let openid4VPlink = String(data: qrCode, encoding: .utf8) else {
			throw PresentationSession.makeError(str: "QR_DATA_MALFORMED")
		}
		self.openid4VPlink = openid4VPlink
		self.openId4VpVerifierApiUri = openId4VpVerifierApiUri
	}
	
	public func startQrEngagement() async throws -> Data? { nil }
	
	///  Receive request from an openid4vp URL
	///
	/// - Returns: The requested items.
	public func receiveRequest() async throws -> [String: Any] {
		guard status != .error, let openid4VPURI = URL(string: openid4VPlink) else { throw PresentationSession.makeError(str: "Invalid link \(openid4VPlink)") }
		siopOpenId4Vp = SiopOpenID4VP(walletConfiguration: getWalletConf(verifierApiUrl: openId4VpVerifierApiUri))
			switch try await siopOpenId4Vp.authorize(url: openid4VPURI)  {
			case .notSecured(data: _):
				throw PresentationSession.makeError(str: "Not secure request received.")
			case let .jwt(request: resolvedRequestData):
				self.resolvedRequestData = resolvedRequestData
				switch resolvedRequestData {
				case let .vpToken(vp):
					self.presentationDefinition = vp.presentationDefinition
					let items = parsePresentationDefinition(vp.presentationDefinition)
					guard let items else { throw PresentationSession.makeError(str: "Invalid presentation definition") }
					var result: [String: Any] = [UserRequestKeys.valid_items_requested.rawValue: items]
					if let readerCertificateIssuer {
						result[UserRequestKeys.reader_auth_validated.rawValue] = readerAuthValidated
						result[UserRequestKeys.reader_certificate_issuer.rawValue] = readerCertificateIssuer
						result[UserRequestKeys.reader_certificate_validation_message.rawValue] = readerCertificateValidationMessage
					}
					return result
				default: throw PresentationSession.makeError(str: "SiopAuthentication request received, not supported yet.")
				}
			}
	}
	
	/// Send response via openid4vp
	///
	/// - Parameters:
	///   - userAccepted: True if user accepted to send the response
	///   - itemsToSend: The selected items to send organized in document types and namespaces
	public func sendResponse(userAccepted: Bool, itemsToSend: RequestItems, onSuccess: ((URL?) -> Void)?) async throws {
		guard let pd = presentationDefinition, let resolved = resolvedRequestData else {
			throw PresentationSession.makeError(str: "Unexpected error")
		}
		guard userAccepted, itemsToSend.count > 0 else {
			try await SendVpToken(nil, pd, resolved, onSuccess)
			return
		}
		logger.info("Openid4vp request items: \(itemsToSend)")
		guard let (deviceResponse, _, _) = try MdocHelpers.getDeviceResponseToSend(deviceRequest: nil, deviceResponses: docs, selectedItems: itemsToSend, dauthMethod: dauthMethod) else { throw PresentationSession.makeError(str: "DOCUMENT_ERROR") }
		// Obtain consent
		let vpTokenStr = Data(deviceResponse.toCBOR(options: CBOROptions()).encode()).base64URLEncodedString()
		try await SendVpToken(vpTokenStr, pd, resolved, onSuccess)
	}
	
	fileprivate func SendVpToken(_ vpTokenStr: String?, _ pd: PresentationDefinition, _ resolved: ResolvedRequestData, _ onSuccess: ((URL?) -> Void)?) async throws {
		let consent: ClientConsent = if let vpTokenStr { .vpToken(vpToken: vpTokenStr, presentationSubmission: .init(id: pd.id, definitionID: pd.id, descriptorMap: [])) } else { .negative(message: "Rejected") }
		// Generate a direct post authorisation response
		let response = try AuthorizationResponse(resolvedRequest: resolved, consent: consent, walletOpenId4VPConfig: getWalletConf(verifierApiUrl: openId4VpVerifierApiUri))
		let result: DispatchOutcome = try await siopOpenId4Vp.dispatch(response: response)
		if case let .accepted(url) = result {
			logger.info("Dispatch accepted, return url: \(url?.absoluteString ?? "")")
			onSuccess?(url)
		} else if case let .rejected(reason) = result {
			logger.info("Dispatch rejected, reason: \(reason)")
			throw PresentationSession.makeError(str: reason)
		}
	}
	
	/// Parse mDoc request from presentation definition (Presentation Exchange 2.0.0 protocol)
	func parsePresentationDefinition(_ presentationDefinition: PresentationDefinition) -> RequestItems? {
		guard let fieldConstraints = presentationDefinition.inputDescriptors.first?.constraints.fields else { return nil }
		guard let docType = fieldConstraints.first(where: {$0.paths.first == "$.mdoc.doctype" })?.filter?["const"] as? String else { return nil }
		guard let namespace = fieldConstraints.first(where: {$0.paths.first == "$.mdoc.namespace" })?.filter?["const"] as? String else { return nil }
		let requestedFields = fieldConstraints.filter { $0.intentToRetain != nil }.compactMap { $0.paths.first?.replacingOccurrences(of: "$.mdoc.", with: "") }
		return [docType:[namespace:requestedFields]]
	}
	
	lazy var chainVerifier: CertificateTrust = { [weak self] certificates in
		let chainVerifier = X509CertificateChainVerifier()
		let verified = try? chainVerifier.verifyCertificateChain(base64Certificates: certificates)
		var result = chainVerifier.isChainTrustResultSuccesful(verified ?? .failure)
		guard let self, let b64cert = certificates.first, let data = Data(base64Encoded: b64cert), let str = String(data: data, encoding: .utf8) else { return result }
		guard let encodedData = Data(base64Encoded: str.removeCertificateDelimiters()), let cert = SecCertificateCreateWithData(nil, encodedData as CFData) else { return result }
		var cfName: CFString?; SecCertificateCopyCommonName(cert, &cfName); self.readerCertificateIssuer = cfName as String?
		let (isValid, reason, _) = SecurityHelpers.isValidMdlPublicKey(secCert: cert, usage: .mdocAuth, rootCerts: self.iaca)
		self.readerAuthValidated = isValid
		self.readerCertificateValidationMessage = reason
		return result
	}
	
	/// OpenId4VP wallet configuration
	func getWalletConf(verifierApiUrl: String?) -> WalletOpenId4VPConfiguration? {
		guard let rsaPrivateKey = try? KeyController.generateRSAPrivateKey(), let privateKey = try? KeyController.generateECDHPrivateKey(),
					let rsaPublicKey = try? KeyController.generateRSAPublicKey(from: rsaPrivateKey) else { return nil }
		guard let rsaJWK = try? RSAPublicKey(publicKey: rsaPublicKey, additionalParameters: ["use": "sig", "kid": UUID().uuidString, "alg": "RS256"]) else { return nil }
		guard let keySet = try? WebKeySet(jwk: rsaJWK) else { return nil }
		var supportedClientIdSchemes: [SupportedClientIdScheme] = [.x509SanDns(trust: chainVerifier), .x509SanDns(trust: chainVerifier)]
		if let verifierApiUrl {
			let verifierMetaData = PreregisteredClient(clientId: "Verifier", jarSigningAlg: JWSAlgorithm(.RS256), jwkSetSource: WebKeySource.fetchByReference(url: URL(string: "\(verifierApiUrl)/wallet/public-keys.json")!))
			supportedClientIdSchemes += [.preregistered(clients: [verifierMetaData.clientId: verifierMetaData])]
	  }
		let res = WalletOpenId4VPConfiguration(subjectSyntaxTypesSupported: [.decentralizedIdentifier, .jwkThumbprint], preferredSubjectSyntaxType: .jwkThumbprint, decentralizedIdentifier: try! DecentralizedIdentifier(rawValue: "did:example:123"), signingKey: privateKey, signingKeySet: keySet, supportedClientIdSchemes: supportedClientIdSchemes, vpFormatsSupported: [])
		return res
	}
	
}

