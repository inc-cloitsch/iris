library remote_services;

import "dart:io";
export "dart:async";
import "dart:async";
import "dart:mirrors";
import "dart:convert";



import "package:logging/logging.dart";
import "package:route/server.dart";
import "package:protobuf/protobuf.dart";
import "annotations.dart" as annotations;


import "package:annotation_crawler/annotation_crawler.dart" as annotation_crawler;



part "src/exceptions.dart";
part "src/server.dart";
part "src/service.dart";





Logger log = new Logger("RemoteServices");



/**
 * The base class for context classes. Every route gets an instance of this
 * class (or a subclass of it) as first parameter when invoked.
 *
 * You can define your own context class by calling
 * [RemoteServices.setContextInitializer].
 */
class Context {

   final ServiceRequest request;

   Context(this.request);
}


/**
 * The type of a filter function used in a [annotations.Route] annotation.
 */
typedef Future<bool> FilterFunction(Context context);


/**
 * The type of context initializer functions
 */
typedef Future<Context> ContextInitializer(ServiceRequest req);




/**
 * Holds all necessary information to invoke a route on a [Service].
 *
 * You can create [ServiceRoute]s by calling [RemoteServices.addService].
 */
class ServiceRoute {

  /// The instance of the service this route will be called on.
  final Service service;

  /// The expected [GeneratedMessage] type this route expects.
  final Type expectedRequestType;

  /// The returned [GeneratedMessage] type.
  final Type returnedType;

  /// The actual method to invoke when this route is called.
  final MethodMirror method;

  /// The list of filter functions for this specific route.
  final List<FilterFunction> filterFunctions;



  ServiceRoute(this.service, this.method, this.expectedRequestType, this.returnedType, this.filterFunctions);

  /// Returns the generated path for this route. Either to be used as HTTP path
  /// or as name for sockets.
  String get path => "/$serviceName.$methodName";

  String get serviceName => service.runtimeType.toString();

  String get methodName => MirrorSystem.getName(method.simpleName);

  /**
   * Invokes the route with [Context] and the [requestMessage] and returns the
   * resulting [GeneratedMessage].
   */
  Future<GeneratedMessage> invoke(Context context, GeneratedMessage requestMessage) {
    return reflect(service).invoke(method.simpleName, [context, requestMessage]).reflectee;
  }

}


/**
 * The base class for the remote_service server. This is your starting point for
 * a remote services server.
 */
class ServiceDefinitions {

  final ContextInitializer _contextInitializer;

  ContextInitializer get contextInitializer => _contextInitializer == null ? _defaultContextInitializer : _contextInitializer;

  ServiceDefinitions([this._contextInitializer]);

  Future<Context> _defaultContextInitializer(ServiceRequest req) => new Future.value(new Context(req));


  /// The list of all [ServiceRoute]s available.
  List<ServiceRoute> routes = [];

  /// The list of all servers configured for those services.
  List<ServiceServer> servers = [];

  /**
   * Checks the service, and creates a list of [ServiceRoute]s for every
   * [Route] found in the service.
   */
  addService(Service service) {
    if (servers.length != 0) throw new RemoteServicesException("You can't add a service after servers have been added.");

    for (var annotatedRoute in annotation_crawler.annotatedDeclarations(annotations.Route, on: reflectClass(service.runtimeType))) {

      if (annotatedRoute.declaration is MethodMirror) {
        MethodMirror method = annotatedRoute.declaration;

        annotations.Route annotation = annotatedRoute.annotation;


        /// Now check that the method is actually of type [RouteMethod].
        /// See: http://stackoverflow.com/questions/23497032/how-do-check-if-a-methodmirror-implements-a-typedef

        TypeMirror returnType = method.returnType.typeArguments.first;

        // Using `.isSubtypeOf` here doesn't work because Future has Generics.
        if (method.returnType.qualifiedName != const Symbol("dart.async.Future") ||
            !returnType.isSubtypeOf(reflectClass(GeneratedMessage))) {
          throw new InvalidServiceDeclaration("Every route needs to return a Future containing a GeneratedMessage.", service);
        }


        if (method.parameters.length != 2 ||
            !method.parameters.first.type.isSubtypeOf(reflectClass(Context)) ||
            !method.parameters.last.type.isSubtypeOf(reflectClass(GeneratedMessage))) {
          throw new InvalidServiceDeclaration("Every route needs to accept a Context and a GeneratedMessage object as parameters.", service);
        }

        var serviceRoute = new ServiceRoute(service, method, method.parameters.last.type.reflectedType, returnType.reflectedType, annotation.filters);
        log.fine("Found route ${serviceRoute.methodName} on service ${serviceRoute.serviceName}");
        routes.add(serviceRoute);
      }
    }
  }


  /**
   * Sets all routes on the server and adds it to the list.
   */
  addServer(ServiceServer server) {
    if (routes.isEmpty) throw new RemoteServicesException("You tried to add a server but no routes have been added yet.");

    server._routes = routes;
    server._contextInitializer = contextInitializer;
    servers.add(server);
  }


  /**
   * Starts all servers
   */
  Future startServers() {
    return Future.wait(servers.map((server) => server.start()));
  }


}





