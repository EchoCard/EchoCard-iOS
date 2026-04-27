//
//  ChatMessagePersistenceDTO.swift
//  CallMate
//
//  Shared Codable shape for legacy UserDefaults JSON and SwiftData mapping helpers.
//

import Foundation

/// Mirrors the JSON previously stored under `messagesPersistenceKey` UserDefaults keys.
struct PersistedExtendedMessage: Codable {
    let id: Int
    let senderRaw: String
    let text: String
    let isAudio: Bool
    let duration: Int?
    let msgTypeRaw: String
    let isConfirmed: Bool
    let proposalStatusRaw: String?
    let proposalCreatedAt: Date?
    let proposalTitle: String?
    let proposalBefore: String?
    let proposalAfter: String?
    let guideImageId: String?
    let guideImageCaption: String?
    let outboundPhone: String?
    let outboundContactName: String?
    let outboundGoal: String?
    let outboundKeyPoints: String?
    let outboundTemplateName: String?
    let outboundScheduledAt: Date?
    let outboundTimeDescription: String?
    let proposalFailureMessage: String?

    init(from message: ExtendedMessage) {
        self.id = message.id
        self.senderRaw = message.sender.rawValue
        self.text = message.text
        self.isAudio = message.isAudio
        self.duration = message.duration
        self.msgTypeRaw = message.msgType.rawValue
        self.isConfirmed = message.isConfirmed
        self.proposalStatusRaw = message.proposalStatus.rawValue
        self.proposalCreatedAt = message.proposalCreatedAt
        self.proposalTitle = message.proposalData?.title
        self.proposalBefore = message.proposalData?.before
        self.proposalAfter = message.proposalData?.after
        self.guideImageId = message.guideImageData?.imageId
        self.guideImageCaption = message.guideImageData?.caption
        self.outboundPhone = message.outboundConfirmationData?.phone
        self.outboundContactName = message.outboundConfirmationData?.contactName
        self.outboundGoal = message.outboundConfirmationData?.goal
        self.outboundKeyPoints = message.outboundConfirmationData?.keyPoints
        self.outboundTemplateName = message.outboundConfirmationData?.templateName
        self.outboundScheduledAt = message.outboundConfirmationData?.scheduledAt
        self.outboundTimeDescription = message.outboundConfirmationData?.timeDescription
        self.proposalFailureMessage = message.proposalFailureMessage
    }

    func toExtendedMessage() -> ExtendedMessage? {
        guard let sender = ChatSender(rawValue: senderRaw),
              let msgType = ExtendedMessageType(rawValue: msgTypeRaw) else {
            return nil
        }
        let proposal: ProposalData?
        if let title = proposalTitle, let before = proposalBefore, let after = proposalAfter {
            proposal = ProposalData(title: title, before: before, after: after)
        } else {
            proposal = nil
        }
        let guideImage: GuideImageData?
        if let imageId = guideImageId, !imageId.isEmpty {
            guideImage = GuideImageData(imageId: imageId, caption: guideImageCaption)
        } else {
            guideImage = nil
        }
        let outboundConfirmation: OutboundConfirmationData?
        if let outboundPhone, let outboundTemplateName,
           !outboundPhone.isEmpty, !outboundTemplateName.isEmpty {
            outboundConfirmation = OutboundConfirmationData(
                phone: outboundPhone,
                contactName: outboundContactName,
                goal: outboundGoal,
                keyPoints: outboundKeyPoints,
                templateName: outboundTemplateName,
                scheduledAt: outboundScheduledAt,
                timeDescription: outboundTimeDescription
            )
        } else {
            outboundConfirmation = nil
        }
        let fallbackStatus: ProposalStatus = isConfirmed ? .applied : .pending
        return ExtendedMessage(
            id: id,
            storageSortIndex: nil,
            sender: sender,
            text: text,
            isAudio: isAudio,
            duration: duration,
            msgType: msgType,
            proposalData: proposal,
            guideImageData: guideImage,
            outboundConfirmationData: outboundConfirmation,
            isConfirmed: isConfirmed,
            proposalStatus: ProposalStatus(rawValue: proposalStatusRaw ?? "") ?? fallbackStatus,
            proposalCreatedAt: proposalCreatedAt,
            proposalFailureMessage: proposalFailureMessage
        )
    }

    init(from row: AIChatMessage) {
        self.id = row.legacyMessageId
        self.senderRaw = row.senderRaw
        self.text = row.text
        self.isAudio = row.isAudio
        self.duration = row.duration
        self.msgTypeRaw = row.msgTypeRaw
        self.isConfirmed = row.isConfirmed
        self.proposalStatusRaw = row.proposalStatusRaw
        self.proposalCreatedAt = row.proposalCreatedAt
        self.proposalTitle = row.proposalTitle
        self.proposalBefore = row.proposalBefore
        self.proposalAfter = row.proposalAfter
        self.guideImageId = row.guideImageId
        self.guideImageCaption = row.guideImageCaption
        self.outboundPhone = row.outboundPhone
        self.outboundContactName = row.outboundContactName
        self.outboundGoal = row.outboundGoal
        self.outboundKeyPoints = row.outboundKeyPoints
        self.outboundTemplateName = row.outboundTemplateName
        self.outboundScheduledAt = row.outboundScheduledAt
        self.outboundTimeDescription = row.outboundTimeDescription
        self.proposalFailureMessage = row.proposalFailureMessage
    }
}
