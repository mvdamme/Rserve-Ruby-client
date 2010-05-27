module Rserve
  class Connection < Rserve::Engine
    include Rserve::Protocol
    
    # :section: Exceptions
    RserveNotStarted=Class.new(Exception)
    ServerNotAvailable=Class.new(Exception)
    IncorrectServer=Class.new(Exception)
    IncorrectServerVersion=Class.new(Exception)
    IncorrectProtocol=Class.new(Exception)
    NotConnected=Class.new(Exception)
    # Eval error
    class EvalError < RuntimeError
      attr_accessor :request_packet
      def initialize(rp)
        @request_packet=rp
      end
    end
    attr_reader :hostname
    attr_reader :port_number
    attr_reader :protocol 
    attr_reader :last_error
    attr_reader :connected
    attr_reader :auth_req
    attr_reader :auth_type
    attr_reader :key
    attr_reader :rt
    attr_reader :s
    attr_reader :port
    attr_writer :transfer_charset
    attr_reader :rsrv_version
    AT_plain=0
    AT_crypt=1
    
    def initialize(opts=Hash.new)
      @auth_req         = opts.delete(:auth_req)          || false
      @transfer_charset = opts.delete(:transfer_charset)  || "UTF-8"
      @auth_type        = opts.delete(:auth_type)         || AT_plain
      @hostname         = opts.delete(:hostname)          || "127.0.0.1"
      @port_number      = opts.delete(:port_number)       || 6311
      @max_tries        = opts.delete(:max_tries)         || 5

      @tries            = 0
      @connected=false
      
      
      begin 
        #puts "Tryin to connect..."
        connect
      rescue Errno::ECONNREFUSED
        if @tries<@max_tries
           @tries+=1
           # Rserve is available?
           if system "killall -s 0 Rserve"
             # Rserve is available. Incorrect host and/or portname
             raise ServerNotAvailable, "Rserve started, but not available on #{hostname}:#{port_number}"
           # Rserve not available. We should instanciate it first
           else 
             if system "R CMD Rserve"
               # Wait a moment please
               sleep(0.25)
             retry
              else
                raise RserveNotStarted, "Can't start Rserve"
              end
           end
          #puts "Init RServe"
          
        else
          raise
        end
      end
    end
    def connect
        close if @connected
        @s = TCPSocket::new(@hostname, @port_number)
        @rt=Rserve::Talk.new(@s)
        #puts "Connected"
        # Accept first input
        input=@s.recv(32).unpack("a4a4a4a20")
        raise IncorrectServer,"Handshake failed: Rsrv signature expected, but received [#{input[0]}]" unless input[0]=="Rsrv"
        @rsrv_version=input[1].to_i
        raise IncorrectServerVersion, "Handshake failed: The server uses more recent protocol than this client." if @rsrv_version>103
        @protocol=input[2]
        raise IncorrectProtocol, "Handshake failed: unsupported transfer protocol #{@protocol}, I talk only QAP1." if @protocol!="QAP1"
        @extra=input[4]
        @connected=true
        @last_error="OK"

    end
    def connected?
      @connected
    end
    def close
      if !@s.nil? and !@s.closed?
        @s.close_write
        @s.close_read
      end
      raise "Can't close socket" unless @s.closed?
      @connected=false
      true
    end
    def get_server_version
      @rsrv_version
    end
    
    # evaluates the given command, but does not fetch the result (useful for assignment operations)
    # * @param cmd command/expression string */
    def void_eval(cmd) 
      raise NotConnected if !connected? or rt.nil?
      rp=rt.request(:cmd=>Rserve::Protocol::CMD_voidEval, :cont=>cmd+"\n")
      if !rp.nil? and rp.ok?
        true
      else
        raise EvalError.new(rp), "voidEval failed: #{rp.to_s}"
      end
      
    end
    
    
  # evaluates the given command and retrieves the result
  # * @param cmd command/expression string
  # * @return R-xpression or <code>null</code> if an error occured */
  def eval(cmd) 
    raise NotConnected if !connected? or rt.nil?
    rp=rt.request(:cmd=>Rserve::Protocol::CMD_eval, :cont=>cmd+"\n")
    if !rp.nil? and rp.ok?
      parse_eval_response(rp)
    else
      raise EvalError.new(rp), "voidEval failed: #{rp.to_s}"
    end
  end
  
  # NOT TESTED
  def parse_eval_response(rp)
    rxo=0
    pc=rp.cont
    if (rsrv_version>100) # /* since 0101 eval responds correctly by using DT_SEXP type/len header which is 4 bytes long */
      rxo=4
      # we should check parameter type (should be DT_SEXP) and fail if it's not
	if (pc[0]!=Rserve::Protocol::DT_SEXP && pc[0]!=(Rserve::Protocol::DT_SEXP|Rserve::Protocol::DT_LARGE))
	raise "Error while processing eval output: SEXP (type "+Rserve::Protocol::DT_SEXP+") expected but found result type "+pc[0].to_s+"."
      end
	if (pc[0]==(Rserve::Protocol::DT_SEXP|Rserve::Protocol::DT_LARGE))
	rxo=8; # large data need skip of 8 bytes
      end
    # warning: we are not checking or using the length - we assume that only the one SEXP is returned. This is true for the current CMD_eval implementation, but may not be in the future. */
    end
    if pc.length>rxo 
      rx=REXPFactory.new;
      rx.parse_REXP(pc, rxo);
      return rx.get_REXP();
    else
        return nil
    end
  end
  
  #assign a string value to a symbol in R. The symbol is created if it doesn't exist already.
  # @param sym symbol name. Currently assign uses CMD_setSEXP command of Rserve, i.e. the symbol value is NOT parsed. It is the responsibility of the user to make sure that the symbol name is valid in R (recall the difference between a symbol and an expression!). In fact R will always create the symbol, but it may not be accessible (examples: "bar\nfoo" or "bar$foo").
  # @param ct contents
    def assign(sym, ct) 
    raise NotConnected if !connected? or rt.nil?
    case ct
      when String
        assign_string(sym,ct)
      when REXP
        assign_rexp(sym,ct)
      else
        raise "Should be String or REXP"
      end
    end
  def assign_string(sym,ct)
    symn = sym.unpack("C*")
    ctn  = ct.unpack("C*")
    sl=symn.length+1
    cl=ctn.length+1
    sl=(sl&0xfffffc)+4 if ((sl&3)>0)  # make sure the symbol length is divisible by 4
    cl=(cl&0xfffffc)+4 if ((cl&3)>0)  # make sure the content length is divisible by 4
    rq=Array.new(sl+4+cl+4)
    symn.length.times {|i| rq[i+4]=symn[i]}
    ic=symn.length
    while (ic<sl) 
      rq[ic+4]=0
      ic+=1
    end
    ctn.length.times {|i| rq[i+sl+8]=ctn[i]}
    ic=ctn.length
    while (ic<cl) 
      rq[ic+sl+8]=0
      ic+=1
    end
    set_hdr(Rserve::Protocol::DT_STRING,sl,rq,0)
    set_hdr(Rserve::Protocol::DT_STRING,cl,rq,sl+4)   
    rp=rt.request(:cmd=>Rserve::Protocol::CMD_setSEXP,:cont=>rq)
    if (!rp.nil? and rp.ok?) 
      rp
    else
      raise "Assign Failed"
    end
  end
  def assign_rexp(sym, rexp)
    r = REXPFactory.new(rexp);
    rl=r.get_binary_length();
    symn=sym.unpack("C*");
    sl=symn.length+1;
    sl=(sl&0xfffffc)+4 if ((sl&3)>0) # make sure the symbol length is divisible by 4
    rq=Array.new(sl+rl+((rl>0xfffff0) ? 12 : 8));
    symn.length.times {|i| rq[i+4]=symn[i]}
    ic=symn.length
    while(ic<sl) 
      rq[ic+4]=0;
      ic+=1; 
    end # pad with 0
    
    set_hdr(Rserve::Protocol::DT_STRING,sl,rq,0)
    set_hdr(Rserve::Protocol::DT_SEXP,rl,rq,sl+4);
    r.get_binary_representation(rq, sl+((rl>0xfffff0) ? 12 : 8));
    # puts "ASSIGN RQ: #{rq}" if $DEBUG
    rp=rt.request(:cmd=>Rserve::Protocol::CMD_setSEXP, :cont=>rq)
    if (!rp.nil? and rp.ok?) 
      rp
    else
      raise "Assign Failed"
    end
  end
end
end
