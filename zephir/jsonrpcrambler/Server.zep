namespace JsonRpcRambler;

use JsonRpcRambler\Exceptions\AccessDeniedException;
use JsonRpcRambler\Exceptions\AuthenticationFailure;
use JsonRpcRambler\Exceptions\InvalidJsonFormat;
use JsonRpcRambler\Exceptions\InvalidJsonRpcFormat;
use JsonRpcRambler\Exceptions\ResponseEncodingFailure;
use JsonRpcRambler\Exceptions\ResponseException;

/**
 * JsonRPC server class
 *
 * @package JsonRPC
 * @author  Frederic Guillot
 */
class Server
{
    /**
     * Data received from the client
     *
     * @access private
     * @var array
     */
    private payload = [];
    /**
     * List of procedures
     *
     * @access private
     * @var array
     */
    private callbacks = [];
    /**
     * List of classes
     *
     * @access private
     * @var array
     */
    private classes = [];
    /**
     * List of instances
     *
     * @access private
     * @var array
     */
    private instances = [];
    /**
     * List of exception classes that should be relayed to client
     *
     * @access private
     * @var array
     */
    private exceptions = [];
    /**
     * Method name to execute before the procedure
     *
     * @access private
     * @var string
     */
    private before = "";
    /**
     * Username
     *
     * @access private
     * @var string
     */
    private username = "";
    /**
     * Password
     *
     * @access private
     * @var string
     */
    private password = "";

    /**
     * Constructor
     *
     * @access public
     * @param  string request
     */
    public function __construct(request = "")
    {
        if (request !== "") {
            let this->payload = json_decode(request, true);
        } else {
            let this->payload = json_decode(file_get_contents("php://input"), true);
        }
    }

    /**
     * Set a payload
     *
     * @access public
     * @param  array payload
     * @return Server
     */
    public function setPayload(array payload)
    {
        let this->payload = payload;
    }
    /**
     * Define alternative authentication header
     *
     * @access public
     * @param  string header Header name
     * @return Server
     */
    public function setAuthenticationHeader(string header)
    {
        var header_array;
        if (!empty(header)) {
            let header = "HTTP_" . str_replace("-", "_", strtoupper(header));
            if (isset(_SERVER[header])) {
                let header_array = explode(":", base64_decode(_SERVER[header]));
                let this->username = header_array[0];
                let this->password = header_array[1];
            }
        }
        return this;
    }

    /**
     * Get username
     *
     * @access public
     * @return string
     */
    public function getUsername()
    {
        return this->username ?: _SERVER["PHP_AUTH_USER"];
    }
    /**
     * Get password
     *
     * @access public
     * @return string
     */
    public function getPassword()
    {
        return this->password ?: _SERVER["PHP_AUTH_PW"];
    }

    /**
     * Send authentication failure response
     *
     * @access public
     */
    public function sendAuthenticationFailureResponse(payload = [])
    {
        header("WWW-Authenticate: Basic realm=\"JsonRPC\"");
        header("Content-Type: application/json");
        header("HTTP/1.0 401 Unauthorized");
        // A notification (request without id) does not expect a response
        if (! is_array(payload) ||  ! array_key_exists("id", payload)) {
            let payload["id"] = 1;
        }

        echo "{ \"jsonrpc\" : \"2.0\", \"id\" : \"" . payload["id"] . "\", \"error\" : { \"code\" : \"401\", \"message\" : \"Authentication failed\" } }";
        return;
    }

    /**
     * Send forbidden response
     *
     * @access public
     */
    public function sendForbiddenResponse(payload = [])
    {
        header("Content-Type: application/json");
        header("HTTP/1.0 403 Forbidden");
        // A notification (request without id) does not expect a response
        if (! is_array(payload) ||  ! array_key_exists("id", payload)) {
            let payload["id"] = 1;
        }

        echo "{ \"jsonrpc\" : \"2.0\", \"id\" : \"" . payload["id"] . "\", \"error\" : { \"code\" : \"403\", \"message\" : \"Access forbidden\" } }";
        return;
    }

    /**
     * IP based client restrictions
     *
     * Return an HTTP error 403 if the client is not allowed
     *
     * @access public
     * @param  array hosts List of hosts
     */
    public function allowHosts(array hosts)
    {
        if (!in_array(_SERVER["REMOTE_ADDR"], hosts)) {
            this->sendForbiddenResponse();
        }
    }
    /**
     * HTTP Basic authentication
     *
     * Return an HTTP error 401 if the client is not allowed
     *
     * @access public
     * @param  array users Map of username/password
     * @return Server
     */
    public function authentication(array users)
    {
        if (!isset(users[this->getUsername()]) || users[this->getUsername()] !== this->getPassword()) {
            this->sendAuthenticationFailureResponse();
        }
        return this;
    }

    /**
     * Register a new procedure
     *
     * @access public
     * @param  string procedure Procedure name
     * @param  closure callback Callback
     * @return Server
     */
    public function register(string procedure, <\Closure> callback)
    {
        let this->callbacks[procedure] = callback;
        return this;
    }
    /**
     * Bind a procedure to a class
     *
     * @access public
     * @param  string procedure Procedure name
     * @param  mixed class Class name or instance
     * @param  string method Procedure name
     * @return Server
     */
    public function bind(string procedure, class_name, string method = "")
    {
        if (method === "") {
            let method = procedure;
        }
        let this->classes[procedure] = [class_name, method];
        return this;
    }
    /**
     * Bind a class instance
     *
     * @access public
     * @param  mixed instance Instance name
     * @return Server
     */
    public function attach(instance)
    {
        let this->instances[] = instance;
        return this;
    }

    /**
     * Bind an exception
     * If this exception occurs it is relayed to the client as JSON-RPC error
     *
     * @access public
     * @param  mixed exception Exception class. Defaults to all.
     * @return Server
     */
    public function attachException(exception = "Exception")
    {
        let this->exceptions[] = exception;
        return this;
    }
    /**
     * Attach a method that will be called before the procedure
     *
     * @access public
     * @param  string before
     * @return Server
     */
    public function before(string before)
    {
        let this->before = before;
        return this;
    }

    /**
     * Return the response to the client
     *
     * @access public
     * @param  array data Data to send to the client
     * @param  array payload Incoming data
     * @return string
     * @throws ResponseEncodingFailure
     */
    public function getResponse(array data, array payload = [])
    {
        var response, encodedResponse, jsonError, errorMessage;

        if (!array_key_exists("id", payload)) {
            return "";
        }
        let response = [
            "jsonrpc": "2.0",
            "id": payload["id"]
        ];

        let response = array_merge(response, data);
        
        if (!headers_sent()) {
            header("Content-Type: application/json");
        }
        let encodedResponse = json_encode(response);
        let jsonError = json_last_error();
        
        if (jsonError !== JSON_ERROR_NONE) {
            switch (jsonError) {
                case JSON_ERROR_NONE:
                    let errorMessage = "No errors";
                    break;
                case JSON_ERROR_DEPTH:
                    let errorMessage = "Maximum stack depth exceeded";
                    break;
                case JSON_ERROR_STATE_MISMATCH:
                    let errorMessage = "Underflow or the modes mismatch";
                    break;
                case JSON_ERROR_CTRL_CHAR:
                    let errorMessage = "Unexpected control character found";
                    break;
                case JSON_ERROR_SYNTAX:
                    let errorMessage = "Syntax error, malformed JSON";
                    break;
                case JSON_ERROR_UTF8:
                    let errorMessage = "Malformed UTF-8 characters, possibly incorrectly encoded";
                    break;
                default:
                    let errorMessage = "Unknown error";
                    break;
            }
            throw new ResponseEncodingFailure(errorMessage, jsonError);
        }
        return encodedResponse;
    }
    
    /**
     * Parse the payload and test if the parsed JSON is ok
     *
     * @access private
     */
    private function checkJsonFormat()
    {
        if (!is_array(this->payload)) {
            throw new InvalidJsonFormat("Malformed payload");
        }
    }
    /**
     * Test if all required JSON-RPC parameters are here
     *
     * @access private
     */
    private function checkRpcFormat()
    {
        if (!isset(this->payload["jsonrpc"]) ||
            !isset(this->payload["method"]) ||
            !is_string(this->payload["method"]) ||
            this->payload["jsonrpc"] !== "2.0" ||
            (isset(this->payload["params"]) && !is_array(this->payload["params"]))
        ) {
            throw new InvalidJsonRpcFormat("Invalid JSON RPC payload");
        }
    }
    /**
     * Return true if we have a batch request
     *
     * @access public
     * @return boolean
     */
    private function isBatchRequest()
    {
        return array_keys(this->payload) === range(0, count(this->payload) - 1);
    }

    /**
     * Handle batch request
     *
     * @access private
     * @return string
     */
    private function handleBatchRequest()
    {
        var payload, server, response;
        var responses = [];
        
        for payload in this->payload {
            if (!is_array(payload)) {
                let responses[] = this->getResponse(
                    [
                        "error": [
                            "code": -32600,
                            "message": "Invalid Request"
                        ]
                    ],
                    ["id": null]
                );
            } else {
                let server = clone this;
                server->setPayload(payload);

                let response = server->execute();
                if (!empty(response)) {
                    let responses[] = response;
                }
            }
        }
        return empty(responses) ? "" : "[" . implode(",", responses) . "]";
    }
    
    /**
     * Parse incoming requests
     *
     * @access public
     * @return string
     */
    public function execute()
    {
        var result, e, class_name, params;
        try {
            this->checkJsonFormat();
            if (this->isBatchRequest()) {
                return this->handleBatchRequest();
            }
            this->checkRpcFormat();
            let params = isset(this->payload["params"]) && !empty(this->payload["params"]) ? this->payload["params"] : [];
            let result = this->executeProcedure(
                this->payload["method"],
                params
            );

            return this->getResponse(["result": result], this->payload);
        } catch InvalidJsonFormat, e {
            return this->getResponse(
                [
                    "error": [
                        "code": -32700,
                        "message": "Parse error"
                    ]
                ],
                ["id": null]
            );
        } catch InvalidJsonRpcFormat, e {
            return this->getResponse(
                [
                    "error": [
                        "code": -32600,
                        "message": "Invalid Request"
                    ]
                ],
                ["id": null]
            );
        } catch \BadFunctionCallException, e {
            return this->getResponse(
                [
                    "error": [
                        "code": -32601,
                        "message": "Method not found"
                    ]
                ],
                this->payload
            );
        } catch \InvalidArgumentException, e {
            return this->getResponse(
                [
                    "error": [
                        "code": -32602,
                        "message": "Invalid params"
                    ]
                ],
                this->payload
            );
        } catch ResponseEncodingFailure, e {
            return this->getResponse(
                [
                    "error": [
                        "code": -32603,
                        "message": "Internal error",
                        "data": e->getMessage()
                    ]
                ],
                this->payload
            );
        } catch AuthenticationFailure, e {
            this->sendAuthenticationFailureResponse(this->payload);
        } catch AccessDeniedException, e {
            this->sendForbiddenResponse(this->payload);
        } catch ResponseException, e {
            return this->getResponse(
                [
                    "error": [
                        "code": e->getCode(),
                        "message": e->getMessage(),
                        "data": e->getData()
                    ]
                ],
                this->payload
            );
        } catch \Exception, e {
            for class_name in this->exceptions {
                if (e instanceof class_name) {
                    return this->getResponse(
                        [
                            "error": [
                                "code": e->getCode(),
                                "message": e->getMessage()
                            ]
                        ],
                        this->payload
                    );
                }
            }
            throw e;
        }
    }

    /**
     * Execute the procedure
     *
     * @access public
     * @param  string procedure Procedure name
     * @param  array params Procedure params
     * @return mixed
     */
    public function executeProcedure(string procedure, array params = [])
    {
        var instance;
        if (isset(this->callbacks[procedure])) {
            return this->executeCallback(this->callbacks[procedure], params);
        } else {
            if (
                isset(this->classes[procedure])
                && (
                    is_object(this->classes[procedure][0])
                    || (is_string(this->classes[procedure][0]) && class_exists(this->classes[procedure][0]))
                )
                && method_exists(
                this->classes[procedure][0],
                this->classes[procedure][1]
                )
            ) {
                return this->executeMethod(this->classes[procedure][0], this->classes[procedure][1], params);
            }
        }
        for instance in this->instances {
            if (method_exists(instance, procedure)) {
                return this->executeMethod(instance, procedure, params);
            }
        }

        throw new \BadFunctionCallException(sprintf("Unable to find the procedure %s", procedure));
    }

    /**
     * Execute a callback
     *
     * @access public
     * @param  Closure callback Callback
     * @param  array params Procedure params
     * @return mixed
     */
    public function executeCallback(<\Closure> callback, array params)
    {
        var arguments, reflection;
        let reflection = new \ReflectionFunction(callback);
        let arguments = this->getArguments(
            params,
            reflection->getParameters(),
            reflection->getNumberOfRequiredParameters(),
            reflection->getNumberOfParameters()
        );
        return reflection->invokeArgs(arguments);
    }

    /**
     * Execute a method
     *
     * @access public
     * @param  mixed class Class name or instance
     * @param  string method Method name
     * @param  array params Procedure params
     * @return mixed
     */
    public function executeMethod(class_name, string method, array params)
    {
        var instance, arguments, reflection;
        let instance = is_string(class_name) ? new {class_name} : class_name;
        // Execute before action
        if (!empty(this->before)) {
            if (is_callable(this->before)) {
                call_user_func_array(
                    this->before,
                    [this->getUsername(), this->getPassword(), get_class(class_name), method]
                );
            } else {
                if (method_exists(instance, this->before)) {
                    call_user_func([instance, this->before], this->getUsername(), this->getPassword(), get_class(class_name), method);

                }
            }
        }
        let reflection = new \ReflectionMethod(class_name, method);
        let arguments = this->getArguments(
            params,
            reflection->getParameters(),
            reflection->getNumberOfRequiredParameters(),
            reflection->getNumberOfParameters()
        );
        return reflection->invokeArgs(instance, arguments);
    }

    /**
     * Get procedure arguments
     *
     * @access public
     * @param  array request_params Incoming arguments
     * @param  array method_params Procedure arguments
     * @param  integer nb_required_params Number of required parameters
     * @param  integer nb_max_params Maximum number of parameters
     * @return array
     */
    public function getArguments(array request_params, array method_params, nb_required_params, nb_max_params)
    {
        var nb_params;
        let nb_params = count(request_params);
        if (nb_params < nb_required_params) {
            throw new \InvalidArgumentException("Wrong number of arguments");
        }
        if (nb_params > nb_max_params) {
            throw new \InvalidArgumentException("Too many arguments");
        }
        if (this->isPositionalArguments(request_params, method_params)) {
            return request_params;
        }
        return this->getNamedArguments(request_params, method_params);
    }

     /**
     * Return true if we have positional parametes
     *
     * @access public
     * @param  array request_params Incoming arguments
     * @param  array method_params Procedure arguments
     * @return bool
     */
    public function isPositionalArguments(array request_params, array method_params)
    {
        return array_keys(request_params) === range(0, count(request_params) - 1);
    }
    /**
     * Get named arguments
     *
     * @access public
     * @param  array request_params Incoming arguments
     * @param  array method_params Procedure arguments
     * @return array
     */
    public function getNamedArguments(array request_params, array method_params)
    {
        var params, p, name;
        let params = [];
        for p in method_params {
            let name = p->getName();
            if (isset(request_params[name])) {
                let params[name] = request_params[name];
            } else {
                if (p->isDefaultValueAvailable()) {
                    let params[name] = p->getDefaultValue();
                } else {
                    throw new \InvalidArgumentException("Missing argument: " . name);
                }
            }
        }
        return params;
    }
}