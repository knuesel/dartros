import 'dart:async';
import 'dart:io';

import 'package:dartros/src/publisher.dart';
import 'package:dartros/src/ros_xmlrpc_client.dart';
import 'package:dartros/src/subscriber.dart';
import 'package:dartros/src/utils/msg_utils.dart';
import 'package:dartx/dartx.dart';
import 'package:xml/xml.dart';
import 'package:path/path.dart' as path;
import 'package:xml_rpc/client.dart';
import 'package:xml_rpc/simple_server.dart' as rpc_server;
import 'impl/publisher_impl.dart';
import 'impl/subscriber_impl.dart';
import 'utils/log/logger.dart';

import 'ros_xmlrpc_common.dart';
import 'utils/network_utils.dart';
import 'utils/tcpros_utils.dart';

class Node extends rpc_server.XmlRpcHandler
    with XmlRpcClient, RosParamServerClient, RosXmlRpcClient {
  static Node _node;
  static Node get singleton => _node;
  factory Node(String name, String rosMasterURI) {
    return _node ?? Node._(name, rosMasterURI);
  }
  @override
  String get xmlRpcUri => 'http://${_xmlRpcServer.host}:${_xmlRpcServer.port}';
  @override
  int get tcpRosPort => _tcpRosServer.port;
  @override
  String nodeName;
  Completer<bool> nodeReady = Completer();
  Node._(this.nodeName, this.rosMasterURI)
      : super(methods: {}, codecs: [...standardCodecs, xmlRpcResponseCodec]) {
    logDir = path.join(homeDir, 'log');
    Logger.logLevel = Level.warning;
    logger = Logger('');
    logger.error('Logging');
    logger.warn('Logging');
    print('here');
    _startServers();

    ProcessSignal.sigint.watch().listen((sig) => shutdown());
  }
  Future<void> _startServers() async {
    await _startTcpRosServer();
    await _startXmlRpcServer();
    nodeReady.complete();
  }

  final Map<String, PublisherImpl> _publishers = {};
  final Map<String, SubscriberImpl> _subscribers = {};
  StreamSubscription<Socket> _tcpStream;
  bool _ok = true;
  bool get ok => _ok;
  Map<String, PublisherImpl> publishers = {};
  Map<String, SubscriberImpl> subscribers = {};
  Map<String, dynamic> servers = {};
  Logger logger;
  String homeDir = Platform.environment['ROS_HOME'] ??
      path.join(Platform.environment['HOME'], '.ros');
  String namespace = Platform.environment['ROS_NAMESPACE'] ?? '';
  String logDir;
  final String rosMasterURI;
  rpc_server.SimpleXmlRpcServer _xmlRpcServer;
  ServerSocket _tcpRosServer;

  bool get isShutdown => !ok;

  Future<void> printRosServerInfo() async {
    final response = await getSystemState();
    print(response);
  }

  Future<void> shutdown() async {
    logger.debug('Shutting node down');
    logger.debug('Shutdown tcprosServer');
    await _stopTcpRosServer();
    _ok = false;
    logger.debug('Shutdown subscribers');
    for (final s in subscribers.values) {
      s.shutdown();
    }
    logger.debug('Shutdown subscribers...done');
    logger.debug('Shutdown publishers');
    for (final p in publishers.values) {
      p.shutdown();
    }
    logger.debug('Shutdown publishers...done');
    logger.debug('Shutdown servers');
    for (final s in servers.values) {
      s.shutdown();
    }
    logger.debug('Shutdown servers...done');
    logger.debug('Shutdown XMLRPC server');
    await _stopXmlRpcServer();
    logger.debug('Shutdown XMLRPC server...done');
    logger.debug('Shutting node done completed');
    exit(0);
  }

  void spinOnce() async {
    await Future.delayed(10.milliseconds);
    processJobs();
  }

  void spin() async {
    while (_ok) {
      await Future.delayed(1.seconds);
      processJobs();
    }
  }

  void processJobs() {}

  Publisher<T> advertise<T extends RosMessage<T>>(
    String topic,
    T typeClass,
    bool latching,
    bool tcpNoDelay,
    int queueSize,
    int throttleMs,
  ) {
    if (!_publishers.containsKey(topic)) {
      _publishers[topic] = PublisherImpl<T>(
          this, topic, typeClass, latching, tcpNoDelay, queueSize, throttleMs);
    }
    return Publisher<T>(_publishers[topic]);
  }

  Subscriber<T> subscribe<T extends RosMessage<T>>(
      String topic,
      T typeClass,
      void Function(T) callback,
      int queueSize,
      int throttleMs,
      bool tcpNoDelay) {
    if (!_subscribers.containsKey(topic)) {
      _subscribers[topic] = SubscriberImpl(
          this, topic, typeClass, queueSize, throttleMs, tcpNoDelay);
    }
    final sub = Subscriber<T>(_subscribers[topic]);
    sub.messageStream.listen(callback);
    return sub;
  }

  Future<void> unadvertise<T>(String topic) {
    // TODO: log
    final pub = _publishers[topic];
    if (pub != null) {
      _publishers.remove(topic);
      pub.shutdown();
    }
    return unregisterPublisher(topic);
  }

  Future<void> unsubscribe(String topic) {
    // TODO: log
    final sub = _subscribers[topic];
    if (sub != null) {
      _subscribers.remove(topic);
      sub.shutdown();
    }
    return unregisterSubscriber(topic);
  }

  /// The following section is an implementation of the Slave API from here: http://wiki.ros.org/ROS/Slave_API
  /// 1

  /// Starts the server for the slave api
  Future<void> _startXmlRpcServer() async {
    methods.addAll({
      'getBusStats': _handleGetBusStats,
      'getBusInfo': _handleGetBusInfo,
      'getMasterUri': _handleGetMasterUri,
      'shutdown': _handleShutdown,
      'getPid': _handleGetPid,
      'getSubscriptions': _handleGetSubscriptions,
      'getPublications': _handleGetPublications,
      'paramUpdate': _handleParamUpdate,
      'publisherUpdate': _handlePublisherUpdate,
      'requestTopic': _handleRequestTopic,
    });
    _xmlRpcServer = await listenRandomPort(
      10,
      (port) async => rpc_server.SimpleXmlRpcServer(
        host: '0.0.0.0',
        port: port,
        handler: this,
      ),
    );
    await _xmlRpcServer.start();
    print('Started xmlRPCServer');
  }

  /// Stops the server for the slave api
  Future<void> _stopXmlRpcServer() async {
    await _xmlRpcServer.stop(force: true);
  }

  Future<void> _startTcpRosServer() async {
    _tcpRosServer = await listenRandomPort(
      10,
      (port) async => await ServerSocket.bind(
        '0.0.0.0',
        0,
      ),
    );
    print('Start listening');
    _tcpStream = await _tcpRosServer.listen(
      (connection) async {
        print('Got tcp ros connection');
        //TODO: logging

        final listener = connection.asBroadcastStream();
        final message = await listener
            .transform(TCPRosChunkTransformer().transformer)
            .first;

        final header = parseTcpRosHeader(message);
        if (header == null) {
          // TODO: Log error
          connection.add(
              serializeString('Unable to validate connection header $message'));
          await connection.flush();
          await connection.close();
          return;
        }
        print('Got connection header $header');
        if (header.topic != null) {
          final topic = header.topic;
          if (_publishers.containsKey(topic)) {
            _publishers[topic]
                .handleSubscriberConnection(connection, listener, header);
          } else {
            // TODO: Log error
          }
        } else if (header.service != null) {
          // TODO: Service
        } else {
          connection.add(serializeString(
              'Connection header $message has neither topic nor service'));
          await connection.flush();
          await connection.close();
        }
      },
      onError: (e) => print('Socket error for tcp ros $e'),
      onDone: () => print('Closing tcp ros server'),
    );
    print('listening on $tcpRosPort');
  }

  _stopTcpRosServer() {}

  ///
  /// Retrieve transport/topic statistics
  /// Returns (int, str, [XMLRPCLegalValue*]) (code, statusMessage, stats)
  ///
  /// stats is of the form [publishStats, subscribeStats, serviceStats] where
  /// publishStats: [[topicName, messageDataSent, pubConnectionData]...]
  /// subscribeStats: [[topicName, subConnectionData]...]
  /// serviceStats: (proposed) [numRequests, bytesReceived, bytesSent]
  /// pubConnectionData: [connectionId, bytesSent, numSent, connected]*
  /// subConnectionData: [connectionId, bytesReceived, dropEstimate, connected]*
  /// dropEstimate: -1 if no estimate.
  XMLRPCResponse _handleGetBusStats(String callerID) {
    return XMLRPCResponse(StatusCode.FAILURE.asInt, 'Not Implemented', 0);
  }

  /// Retrieve transport/topic connection information.
  ///
  /// Returns (int, str, [XMLRPCLegalValue*]) (code, statusMessage, busInfo)
  /// busInfo is of the form:
  /// [[connectionId1, destinationId1, direction1, transport1, topic1, connected1]... ]
  /// connectionId is defined by the node and is opaque.
  /// destinationId is the XMLRPC URI of the destination.
  /// direction is one of 'i', 'o', or 'b' (in, out, both).
  /// transport is the transport type (e.g. 'TCPROS').
  /// topic is the topic name.
  /// connected1 indicates connection status. Note that this field is only provided by slaves written in Python at the moment (cf. rospy/masterslave.py in _TopicImpl.get_stats_info() vs. roscpp/publication.cpp in Publication::getInfo()).
  XMLRPCResponse _handleGetBusInfo(String callerID) {
    print('get bus info');
    var count = 0;
    return XMLRPCResponse(StatusCode.FAILURE.asInt, 'Not Implemented', [
      for (final sub in subscribers.values)
        for (final client in sub.clientUris)
          [++count, client, 'o', 'TCPROS', sub.topic, true],
      for (final pub in publishers.values)
        for (final client in pub.clientUris)
          [++count, client, 'o', 'TCPROS', pub.topic, true]
    ]);
  }

  /// Gets the URI of the master node
  XMLRPCResponse _handleGetMasterUri(String callerID) {
    print('get master uri');
    return XMLRPCResponse(
        StatusCode.SUCCESS.asInt, StatusCode.SUCCESS.asString, rosMasterURI);
  }

  /// Stop this server.
  ///
  /// [message] A message describing why the node is being shutdown
  XMLRPCResponse _handleShutdown(String callerID, [String message = '']) {
    if (message != null && message.isNotEmpty) {
      print('shutdown request: $message');
    } else {
      print('shutdown request');
    }
    shutdown();
    return XMLRPCResponse(
        StatusCode.SUCCESS.asInt, StatusCode.SUCCESS.asString, 0);
  }

  /// Get the PID of this server.
  ///
  /// returns the PID
  XMLRPCResponse _handleGetPid(String callerID) {
    print('get pid');
    return XMLRPCResponse(
        StatusCode.SUCCESS.asInt, StatusCode.SUCCESS.asString, pid);
  }

  /// Retrieve a list of topics that this node subscribes to
  ///
  /// returns the topicList
  /// topicList is a list of topics this node subscribes to and is of the form
  /// [ [topic1, topicType1]...[topicN, topicTypeN] ]
  XMLRPCResponse _handleGetSubscriptions(String callerID) {
    print('get subscriptions');
    return XMLRPCResponse(
        StatusCode.SUCCESS.asInt, StatusCode.SUCCESS.asString, [
      for (final sub in subscribers.entries) [sub.key, sub.value.type]
    ]);
  }

  /// Retrieve a list of topics that this node publishes
  ///
  /// returns the topicList
  /// topicList is a list of topics this node subscribes to and is of the form
  /// [ [topic1, topicType1]...[topicN, topicTypeN] ]
  XMLRPCResponse _handleGetPublications(String callerID) {
    print('get publications');
    return XMLRPCResponse(
        StatusCode.SUCCESS.asInt, StatusCode.SUCCESS.asString, [
      for (final pub in publishers.entries) [pub.key, pub.value.type]
    ]);
  }

  /// Callback from master with updated value of subscribed parameter.
  ///
  /// [parameterKey] parameter name, globally resolved
  /// [parameterValue] new parameter value
  XMLRPCResponse _handleParamUpdate(
      String callerID, String parameterKey, dynamic parameterValue) {
    print('param update');
    return XMLRPCResponse(StatusCode.FAILURE.asInt, 'Not Implemented', 0);
  }

  /// Callback from master of current publisher list for specified topic
  ///
  /// [topic] Topic name
  /// [publishers] List of current publishers for topic in form of XMLRPC URIs
  XMLRPCResponse _handlePublisherUpdate(
      String callerID, String topic, List<String> publishers) {
    print('Publisher update');
    return XMLRPCResponse(
        StatusCode.SUCCESS.asInt, StatusCode.SUCCESS.asString, 0);
  }

  /// Publisher node API method called by a subscriber node.
  ///
  /// This requests that source allocate a channel for communication.
  /// Subscriber provides a list of desired protocols for communication.
  /// Publisher returns the selected protocol along with any additional params required for establishing connection.
  /// For example, for a TCP/IP-based connection, the source node may return a port number of TCP/IP server.
  ///
  /// [topic] Topic name
  /// [protocols] List of desired protocols for communication in order of preference.
  /// Each protocol is a list of the form
  /// [ProtocolName, ProtocolParam1, ProtocolParam2...N]
  ///
  /// Returns (int, str, [str, !XMLRPCLegalValue*] ) (code, statusMessage, protocolParams)
  /// protocolParams may be an empty list if there are no compatible protocols.
  XMLRPCResponse _handleRequestTopic(
      String callerID, String topic, List<dynamic> protocols) {
    print('Handling request topic');
    List resp;
    if (_publishers.containsKey(topic)) {
      resp = [
        1,
        'Allocated topic connection on port ' + tcpRosPort.toString(),
        ['TCPROS', _tcpRosServer.address.address, tcpRosPort]
      ];
    } else {
      resp = [0, 'Unable to allocate topic connection for ' + topic, []];
    }
    print(resp);
    return XMLRPCResponse(resp[0], resp[1], resp[2]);
  }

  /// Our client's api to request a topic from another node
  Future<ProtocolParams> requestTopic(String remoteAddress, int remotePort,
      String topic, List<List<String>> protocols) {
    final slave = SlaveApiClient(nodeName, remoteAddress, remotePort);
    return slave.requestTopic(topic, protocols);
  }

  @override
  XmlDocument handleFault(Fault fault, {List<Codec> codecs}) {
    print('Error in xmlRPC server $fault');
    return super.handleFault(fault);
  }
}
