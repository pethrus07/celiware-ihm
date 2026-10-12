/// StatusCode do OPC UA: o "deu certo / por que não deu" de cada resposta e
/// de cada nó lido ou gravado (Parte 4, 7.39; números de
/// `Opc.Ua.StatusCodes.csv`, conferidos contra o asyncua 2.1.0).
///
/// Os dois bits mais altos dizem a gravidade: 00 bom, 01 incerto, 10 ruim.
library;

abstract final class UaStatus {
  static const int good = 0x00000000;

  static const int badUnexpectedError = 0x80010000;
  static const int badInternalError = 0x80020000;
  static const int badCommunicationError = 0x80050000;
  static const int badEncodingError = 0x80060000;
  static const int badDecodingError = 0x80070000;
  static const int badTimeout = 0x800A0000;
  static const int badServiceUnsupported = 0x800B0000;
  static const int badShutdown = 0x800C0000;
  static const int badServerHalted = 0x800E0000;
  static const int badTooManyOperations = 0x80100000;
  static const int badCertificateInvalid = 0x80120000;
  static const int badSecurityChecksFailed = 0x80130000;
  static const int badUserAccessDenied = 0x801F0000;
  static const int badIdentityTokenInvalid = 0x80200000;
  static const int badIdentityTokenRejected = 0x80210000;
  static const int badSecureChannelIdInvalid = 0x80220000;
  static const int badNonceInvalid = 0x80240000;
  static const int badSessionIdInvalid = 0x80250000;
  static const int badSessionClosed = 0x80260000;
  static const int badSessionNotActivated = 0x80270000;
  static const int badNoCommunication = 0x80310000;
  static const int badWaitingForInitialData = 0x80320000;
  static const int badNodeIdInvalid = 0x80330000;
  static const int badNodeIdUnknown = 0x80340000;
  static const int badAttributeIdInvalid = 0x80350000;
  static const int badIndexRangeInvalid = 0x80360000;
  static const int badIndexRangeNoData = 0x80370000;
  static const int badNotReadable = 0x803A0000;
  static const int badNotWritable = 0x803B0000;
  static const int badOutOfRange = 0x803C0000;
  static const int badNotSupported = 0x803D0000;
  static const int badNotFound = 0x803E0000;
  static const int badContinuationPointInvalid = 0x804A0000;
  static const int badNoContinuationPoints = 0x804B0000;
  static const int badSecurityModeRejected = 0x80540000;
  static const int badSecurityPolicyRejected = 0x80550000;
  static const int badTooManySessions = 0x80560000;
  static const int badUserSignatureInvalid = 0x80570000;
  static const int badWriteNotSupported = 0x80730000;
  static const int badTypeMismatch = 0x80740000;
  static const int badTcpServerTooBusy = 0x807D0000;
  static const int badTcpMessageTooLarge = 0x80800000;
  static const int badTcpEndpointUrlInvalid = 0x80830000;
  static const int badRequestTimeout = 0x80850000;
  static const int badSecureChannelClosed = 0x80860000;
  static const int badSecureChannelTokenUnknown = 0x80870000;
  static const int badConfigurationError = 0x80890000;
  static const int badNotConnected = 0x808A0000;
  static const int badDeviceFailure = 0x808B0000;
  static const int badSensorFailure = 0x808C0000;
  static const int badOutOfService = 0x808D0000;
  static const int badInvalidArgument = 0x80AB0000;
  static const int badRequestTooLarge = 0x80B80000;
  static const int badResponseTooLarge = 0x80B90000;
  static const int badProtocolVersionUnsupported = 0x80BE0000;
  static const int badLicenseExpired = 0x810E0000;
  static const int badLicenseLimitsExceeded = 0x810F0000;
  static const int badLicenseNotAvailable = 0x81100000;

  static bool isGood(int code) => code & 0xC0000000 == 0;
  static bool isUncertain(int code) => code & 0xC0000000 == 0x40000000;
  static bool isBad(int code) => code & 0x80000000 != 0;

  /// A sessão ou o canal deixaram de existir no servidor (reiniciou, venceu o
  /// tempo): o cliente reabre tudo no próximo pedido.
  static bool killsSession(int code) => const {
        badSessionIdInvalid,
        badSessionClosed,
        badSessionNotActivated,
        badSecureChannelIdInvalid,
        badSecureChannelClosed,
        badSecureChannelTokenUnknown,
        badShutdown,
        badServerHalted,
      }.contains(code & 0xFFFF0000);

  /// O servidor está de pé, mas sem comunicação com o equipamento por trás
  /// dele (gateway, Kepware com o CLP desligado): para a tela é "sem
  /// comunicação", não endereço errado.
  static bool isDeviceComm(int code) => const {
        badNoCommunication,
        badWaitingForInitialData,
        badNotConnected,
        badDeviceFailure,
        badSensorFailure,
        badOutOfService,
        badCommunicationError,
      }.contains(code & 0xFFFF0000);

  /// Nome da norma ("BadNodeIdUnknown"), para log e para o fim das
  /// mensagens sem tradução.
  static String name(int code) => _names[code & 0xFFFF0000] ?? '0x${code.toRadixString(16).padLeft(8, '0').toUpperCase()}';

  static const Map<int, String> _names = {
    good: 'Good',
    badUnexpectedError: 'BadUnexpectedError',
    badInternalError: 'BadInternalError',
    badCommunicationError: 'BadCommunicationError',
    badEncodingError: 'BadEncodingError',
    badDecodingError: 'BadDecodingError',
    badTimeout: 'BadTimeout',
    badServiceUnsupported: 'BadServiceUnsupported',
    badShutdown: 'BadShutdown',
    badServerHalted: 'BadServerHalted',
    badTooManyOperations: 'BadTooManyOperations',
    badCertificateInvalid: 'BadCertificateInvalid',
    badSecurityChecksFailed: 'BadSecurityChecksFailed',
    badUserAccessDenied: 'BadUserAccessDenied',
    badIdentityTokenInvalid: 'BadIdentityTokenInvalid',
    badIdentityTokenRejected: 'BadIdentityTokenRejected',
    badSecureChannelIdInvalid: 'BadSecureChannelIdInvalid',
    badNonceInvalid: 'BadNonceInvalid',
    badSessionIdInvalid: 'BadSessionIdInvalid',
    badSessionClosed: 'BadSessionClosed',
    badSessionNotActivated: 'BadSessionNotActivated',
    badNoCommunication: 'BadNoCommunication',
    badWaitingForInitialData: 'BadWaitingForInitialData',
    badNodeIdInvalid: 'BadNodeIdInvalid',
    badNodeIdUnknown: 'BadNodeIdUnknown',
    badAttributeIdInvalid: 'BadAttributeIdInvalid',
    badIndexRangeInvalid: 'BadIndexRangeInvalid',
    badIndexRangeNoData: 'BadIndexRangeNoData',
    badNotReadable: 'BadNotReadable',
    badNotWritable: 'BadNotWritable',
    badOutOfRange: 'BadOutOfRange',
    badNotSupported: 'BadNotSupported',
    badNotFound: 'BadNotFound',
    badContinuationPointInvalid: 'BadContinuationPointInvalid',
    badNoContinuationPoints: 'BadNoContinuationPoints',
    badSecurityModeRejected: 'BadSecurityModeRejected',
    badSecurityPolicyRejected: 'BadSecurityPolicyRejected',
    badTooManySessions: 'BadTooManySessions',
    badUserSignatureInvalid: 'BadUserSignatureInvalid',
    badWriteNotSupported: 'BadWriteNotSupported',
    badTypeMismatch: 'BadTypeMismatch',
    badTcpServerTooBusy: 'BadTcpServerTooBusy',
    badTcpMessageTooLarge: 'BadTcpMessageTooLarge',
    badTcpEndpointUrlInvalid: 'BadTcpEndpointUrlInvalid',
    badRequestTimeout: 'BadRequestTimeout',
    badSecureChannelClosed: 'BadSecureChannelClosed',
    badSecureChannelTokenUnknown: 'BadSecureChannelTokenUnknown',
    badConfigurationError: 'BadConfigurationError',
    badNotConnected: 'BadNotConnected',
    badDeviceFailure: 'BadDeviceFailure',
    badSensorFailure: 'BadSensorFailure',
    badOutOfService: 'BadOutOfService',
    badInvalidArgument: 'BadInvalidArgument',
    badRequestTooLarge: 'BadRequestTooLarge',
    badResponseTooLarge: 'BadResponseTooLarge',
    badProtocolVersionUnsupported: 'BadProtocolVersionUnsupported',
    badLicenseExpired: 'BadLicenseExpired',
    badLicenseLimitsExceeded: 'BadLicenseLimitsExceeded',
    badLicenseNotAvailable: 'BadLicenseNotAvailable',
  };
}
