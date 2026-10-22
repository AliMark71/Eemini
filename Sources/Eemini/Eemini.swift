// The Swift Programming Language
// https://docs.swift.org/swift-book

import AsyncHTTPClient
import DiscordBM
import Foundation
import WebURL
import Foundation

struct User {
    let discordId: UserSnowflake
    let matrixId: String
    // TODO: add the ability to change the homeserver
    let matrixHomeserver: WebURL
    var token: String
}

// TODO: persistance.
@MainActor
var users: [UserSnowflake: User] = [:]

@main
struct Eemini {
    static func main() async throws {
        func getTokenFromStdin() -> String {
            print("Enter Discord Bot Token: ")
            guard let token = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                print("Either set EEMINI_BOT_TOKEN or provide bot token from stdin")
                exit(1)
            }

            return token
        }

        let botToken = ProcessInfo.processInfo.environment["EEMINI_BOT_TOKEN"] ?? getTokenFromStdin()

        let bot: BotGatewayManager = await BotGatewayManager(
            token: botToken,
            intents: [.directMessages]
        )

        try await withThrowingTaskGroup { group in
            group.addTask {
                await bot.connect()
            }

            group.addTask {
                let commands = EeminiCommand.allCases.map { command in
                    Payloads.ApplicationCommandCreate(
                        name: command.rawValue,
                        description: command.description,
                        options: command.options
                    )
                }

                try await bot
                    .client
                    .bulkSetApplicationCommands(payload: commands)
                    .guardSuccess()

                for await event in await bot.events {
                    await EeminiEventHandler(event: event, client: bot.client).handleAsync()
                }
            }

            try await group.waitForAll()
        }
    }
}

struct EeminiEventHandler: GatewayEventHandler {
    let event: Gateway.Event
    let client: any DiscordClient

    func onInteractionCreate(_ payload: Interaction) async throws {
        switch payload.data {
        case .applicationCommand(let command):
            let eeminiCommand = EeminiCommand(rawValue: command.name)! // asserting that the command exists

            /// You only have 3 second to respond, so it's better to send
            /// the response right away, and edit the response later.
            /// This will show a loading indicator to users.
            try await client.createInteractionResponse(
                id: payload.id,
                token: payload.token,
                payload: .deferredChannelMessageWithSource(isEphemeral: eeminiCommand.isEphemeral)
            ).guardSuccess()

            try await eeminiCommand.handle(command, of: payload, using: client)
        default: fatalError("unimplemented interaction: \(payload.data, default: "<no data>")")
        }
    }

    func onMessageCreate(_ payload: Gateway.MessageCreate) async throws {
        print(payload)
    }
}

enum EeminiCommand: String, CaseIterable, CustomStringConvertible {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()

    case setup
    case setToken = "set-token"
    case copy

    var description: String {
        switch self {
        case .setup: "Setup your Matrix account with the bot. (use first, once)"
        case .setToken: "Update the Matrix token to use for your account."
        case .copy: "Copies an emoticon to your personal pack in Matrix."
        }
    }

    var options: [ApplicationCommand.Option]? {
        switch self {
        case .setup: [
                .init(
                    type: .string,
                    name: "homeserver",
                    description: "The URL to your Matrix homeserver.",
                    required: true
                ),
                .init(
                    type: .string,
                    name: "token",
                    description: "The access token to your Matrix account on your homeserver.",
                    required: true
                )
        ]
        case .setToken: [
                .init(
                    type: .string,
                    name: "token",
                    description: "The access token to your Matrix account on your homeserver.",
                    required: true)
        ]
        case .copy: [
                .init(
                    type: .string,
                    name: "emoticon",
                    description: "The emoticon to be copied to Matrix.",
                    required: true)
        ]
        }
    }

    var isEphemeral: Bool {
        switch self {
        case .setup, .setToken: true
        case .copy: false
        }
    }

    @MainActor
    func handle(
        _ command: Interaction.ApplicationCommand,
        of interaction: Interaction,
        using client: any DiscordClient
    ) async throws {
        // discord API defines a mutex relation between `interaction.user` and `interaction.member`
        // so if `interaction.user` is nil, we force-unwrap `interaction.member` instead,
        // and take the `user` from that
        //
        // more over, the `user` property of `interaction.member` is nil only in `MESSAGE_CREATE` and
        // `MESSAGE_UPDATE` gateway events. so we are force-unwraping that too.
        let discordUser = interaction.user ?? interaction.member!.user!
        let userDiscordId = discordUser.id

        switch self {
        case .setup:
            var user = MutableRef(&users[userDiscordId])
            guard user.value == nil else {
                try await client.updateOriginalInteractionResponse(
                    token: interaction.token,
                    payload: .init(
                        content: "user already setup, if you wanna change the token use /set-token",
                    )
                ).guardSuccess()
                return
            }

            // ! is asserting that the options exist
            let homeserver = try command.option(named: "homeserver")!.requireString()
            let token = try command.option(named: "token")!.requireString()


            guard let homeserverURL = WebURL(homeserver) else {
                try await client.updateOriginalInteractionResponse(
                    token: interaction.token,
                    payload: .init(
                        content: "homeserver was not a valid URL!",
                    )
                ).guardSuccess()
                return
            }

            guard homeserverURL.scheme == "https" else {
                try await client.updateOriginalInteractionResponse(
                    token: interaction.token,
                    payload: .init(
                        content: "homeserver URL needs to be 'https', it was '\(homeserverURL.scheme)'!"
                    )
                ).guardSuccess()
                return
            }


            var whoAmIEndpoint = homeserverURL
            whoAmIEndpoint.pathComponents += ["_matrix", "client", "v3", "account", "whoami"]

            var request = HTTPClientRequest(url: String(whoAmIEndpoint))
            request.bearer(token)

            let response = try await HTTPClient.shared
                .execute(request, timeout: .seconds(10))

            guard response.status == .ok else {
                try await client.updateOriginalInteractionResponse(
                    token: interaction.token,
                    payload: .init(
                        content: "Couldn't login to matrix, check your credential and retry again.",
                    )
                ).guardSuccess()
                print(response)
                return
            }

            let userMatrixId = try await Self.decoder
                .decode(WhoAmI.self, from: response.body.collect(upTo: 1024)).userId

            /// https://spec.matrix.org/v1.11/client-server-api/#get_matrixclientv3accountwhoami
            struct WhoAmI: Codable {
                let userId: String
                let deviceId: String?
                let isGuest: Bool?

                enum CodingKeys: String, CodingKey {
                    case userId = "user_id"
                    case deviceId = "device_id"
                    case isGuest = "is_guest"
                }
            }

            user.value = User(
                discordId: userDiscordId,
                matrixId: userMatrixId,
                matrixHomeserver: homeserverURL,
                token: token
            )
            try await client.updateOriginalInteractionResponse(
                token: interaction.token,
                payload: .init(
                    content: "user successfully created.",
                )
            ).guardSuccess()
        case .setToken:
            // ! is asserting that there is an option "access token"
            let token = try command.option(named: "token")!.requireString()

            var user = MutableRef(&users[userDiscordId])
            guard user.value != nil else {
                try await client.updateOriginalInteractionResponse(
                    token: interaction.token,
                    payload: .init(
                        content: "user not set up, please do /setup first.",
                    )
                ).guardSuccess()
                return
            }

            user.value!.token = token
            try await client.updateOriginalInteractionResponse(
                token: interaction.token,
                payload: .init(
                    content: "token updated",
                )
            ).guardSuccess()
        case .copy:
            guard let user = users[userDiscordId] else {
                try await client.updateOriginalInteractionResponse(
                    token: interaction.token,
                    payload: .init(
                        content: "You didn't setup your matrix account, please use /setup first."
                    )
                ).guardSuccess()
                return
            }

            let discordEmoticonPattern = /<:(?<name>[A-Za-z0-9]{2,32}):(?<id>\d+)>/
            let discordEmoticonRaw = try command.option(named: "emoticon")!.requireString()

            guard let discordEmoticon = discordEmoticonRaw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .wholeMatch(of: discordEmoticonPattern)?.output else {
                try await client.updateOriginalInteractionResponse(
                    token: interaction.token,
                    payload: .init(
                        content: """
                                    womp womp, I can't help with that 👉👈
                                    you have to give a single emoji with nothing else,
                                    or maybe I just can't handle that emoji 😳
                                 """
                    )
                ).guardSuccess()
                return
            }


            let emoticonImageRequest = HTTPClientRequest(
                url: "https://cdn.discordapp.com/emojis/\(discordEmoticon.id).png?size=512",
            )
            let emoticonImageResponse = try await HTTPClient.shared
                .execute(emoticonImageRequest, timeout: .seconds(10))
            let imageBuffer = try await emoticonImageResponse.body.collect(upTo: 15 * 1024)
            let imageMimeType = emoticonImageResponse.headers["Content-Type"].first ?? "image/png"

            var matrixUploadEndpoint = user.matrixHomeserver
            matrixUploadEndpoint.pathComponents += ["_matrix", "media", "v3", "upload"]

            var uploadRequest = HTTPClientRequest(url: String(matrixUploadEndpoint))
            uploadRequest.method = .POST
            uploadRequest.bearer(user.token)
            uploadRequest.headers.add(
                name: "Content-Type",
                value: imageMimeType)
            uploadRequest.body = .bytes(imageBuffer)
            let uploadResponse = try await HTTPClient.shared
                .execute(uploadRequest, timeout: .seconds(10))

            guard uploadResponse.status == .ok else {
                try await client.updateOriginalInteractionResponse(
                    token: interaction.token,
                    payload: .init(
                        content: "Couldn't upload the emoticon to matrix!",
                    )
                ).guardSuccess()
                return
            }

            // `content_ui` not optional per matrix documentation
            // https://spec.matrix.org/v1.11/client-server-api/#post_matrixmediav3upload
            let matrixContentURI = try await Self.decoder
                .decode([String: String].self, from: uploadResponse.body.collect(upTo: 1024))["content_uri"]!

            let personalEmoticonPackEventType = "im.ponies.user_emotes"
            var accountDataEndpoint = user.matrixHomeserver
            accountDataEndpoint.pathComponents += [
                "_matrix", "client", "v3", "user", user.matrixId, "account_data", personalEmoticonPackEventType
            ]

            var accountDataRequest = HTTPClientRequest(url: String(accountDataEndpoint))
            accountDataRequest.bearer(user.token)
            let accountDataResponse = try await HTTPClient.shared
                .execute(accountDataRequest, timeout: .seconds(10))

            guard accountDataResponse.status == .ok else {
                try await client.updateOriginalInteractionResponse(
                    token: interaction.token,
                    payload: .init(
                        content: "Unexpected matrix error!",
                    )
                ).guardSuccess()
                return
            }

            var userEmotesData = try await Self.decoder
                .decode(UserEmotesData.self, from: accountDataResponse.body.collect(upTo: 50 * 1024))

            var matrixEmote = MutableRef(&userEmotesData.images[String(discordEmoticon.name)])

            // TODO: maybe still save the emoticon with the first available name from: {`name1`, `name2` ...}
            guard matrixEmote.value == nil else {
                 try await client.updateOriginalInteractionResponse(
                     token: interaction.token,
                     payload: .init(
                         content: """
                             An emoticon already exists with this name, aborting to avoid overriding it.
                             Please pick a different name.
                             """,
                     )
                 ).guardSuccess()
                 return
            }

            var w: CInt = 0, h: CInt = 0, comp: CInt = 0
            guard stbi_info_from_memory(imageBuffer.readableBytesUInt8Span, &w, &h, &comp) != 0 else {
                 try await client.updateOriginalInteractionResponse(
                     token: interaction.token,
                     payload: .init(
                         content: "woops, something went wrong :>",
                     )
                 ).guardSuccess()
                 return
            }

            matrixEmote.value = UserEmotesData.Image(
                url: matrixContentURI,
                info: .init(
                    w: Int(w),
                    h: Int(h),
                    size: imageBuffer.readableBytes,
                    mimetype: imageMimeType
                )
            )

            accountDataRequest.method = .PUT
            accountDataRequest.body = .bytes(try Self.encoder.encode(userEmotesData))
            let accountDataPatchResponse = try await HTTPClient.shared
                .execute(accountDataRequest, timeout: .seconds(10))

            guard accountDataPatchResponse.status == .ok else {
                 try await client.updateOriginalInteractionResponse(
                     token: interaction.token,
                     payload: .init(
                         content: "Sowwy, couldn't add the emoticon!",
                     )
                 ).guardSuccess()
                 return
            }

            try await client.updateOriginalInteractionResponse(
                token: interaction.token,
                payload: .init(
                    content: """
                        Successfully added the emoticon! 🥳
                        go check it using :\(discordEmoticon.name):
                        """,
                )
            ).guardSuccess()
        }
    }
}

struct UserEmotesData: Codable {
    let pack: Metadata
    var images: [String: Image]

    struct Metadata: Codable {
        let displayName: String
        let attribution: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case attribution
        }
    }

    struct Image: Codable {
        let url: String
        var body: String? = nil
        let info: ImageInfo

        struct ImageInfo: Codable {
            let w, h, size: Int
            let mimetype: String
        }
    }
}

extension HTTPClientRequest {
    mutating func bearer(_ token: String) {
        headers.add(name: "Authorization", value: "Bearer \(token)")
    }
}
