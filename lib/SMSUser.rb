require 'rubygems'
require 'mongo'
require 'twilio-ruby'
begin
	require './local_settings'
rescue LoadError
	require '../local_settings'
end

#
# handles interaction with an SMS user
#
class SMSUser
  
  attr_accessor :general_err
  
  def initialize(phone)
    
    # messages
    @general_err = "Erg. I don't know what to do with that. Text HELP for help."
    @help_msg = "Text your name to subscribe to NYU Startup Week Alerts. Text UNSUBSCRIBE to unsubscribe. \n(Powered by Twilio)"
    @admin_help_msg = "B:[message] to broadcast.\nS:[name],[phone] to subscribe.\nU:[phone] to unsubscribe.\nC to count subscribers"
    @subscribe_msg = "Hello! You are subscribing to Startup Week Alerts as \"%s\". If your name is correct, text YES to confirm. If not, text your name again."
    @subscribe_err = "You are already subscribed to Startup Week Alerts. Text HELP for help."
    @numfmt_err = 'Invalid phone number format. Must be ^\d{10}$'
    @admin_subscribe_msg = "%s (%s) is now subscribed to Startup Week Alerts."
    @admin_subscribe_err = "%s is already subscribed."
    @admin_unsubscribe_msg = "%s has been unsubscribed."
    @admin_unsubscribe_err = "%s is not subscribed."
    @confirm_msg = "Welcome, %s! You are now subscribed to Startup Week Alerts. Text UNSUBSCRIBE to unsubscribe."
    @confirm_err = @general_err
    @unsubscribe_msg = "G'bye! You have unsubscribed from NYU Startup Week Alerts. Text your name to re-subscribe."
    @unsubscribe_err = "You are not subscribed. Text HELP for help."
    @broadcast_msg = "Your message has been queued. Text YES to confirm and broadcast your message to all subscribers. Text another message to replace it."
    @confirm_broadcast_msg = "Your message has been sent."
    @confirm_broadcast_notq_err = "You have no message queued."
    # end messages
    
    @phone = phone
    
    @db_name = 'sw_alerts'
    @users_coll = 'users'
    @users_uc_coll = 'users_uc' # unconfirmed users queue
    @broadcast_queue = 'broadcast_queue'
    @broadcast_archive = 'broadcast_archive'

    @db = Mongo::Connection.new.db(@db_name)
    #TODO verify db connection
  end
  
  #
  # helper: verifies the user is subscribed
  # (unconfirmed=true searches unconfirmed users)
  #
  def is_subscribed(unconfirmed=false)
    coll = unconfirmed===true ? @db[@users_uc_coll] : @db[@users_coll]
    if coll.find_one({'phone' => @phone}) == nil then
      false
    else
      true
    end
  end
  
  #
  # helper: verifies whether the user is admin
  #
  def is_admin
    if $admins.index(@phone) === nil then
      false
    else
      true
    end
  end
  
  #
  # helper: verifies whether user has a broadcast pending
  #
  def has_broadcast_pending
    if @db[@broadcast_queue].find_one({'admin_phone' => @phone}) == nil then
      false
    else
      true
    end
  end
  
  #
  # returns the user specified by the given phone number
  # (unconfirmed=true pulls from unconfirmed users queue)
  #
  def get_user(phone, unconfirmed=false)
    coll = unconfirmed===true ? @db[@users_uc_coll] : @db[@users_coll]
    coll.find_one({'phone' => phone})
  end
  
  #
  # returns the help msg
  #
  def get_help
    if self.is_admin then
      @admin_help_msg
    else
      @help_msg
    end
  end
  
  #
  # subscribes a new user (UNCONFIRMED)
  #
  def subscribe(name)
    return @subscribe_err if self.is_subscribed # must not already be subscribed
    
    @db[@users_uc_coll].remove({'phone' => @phone})
    @db[@users_uc_coll].insert({
      'name' => name,
      'phone' => @phone,
      'ts' => Time.now.to_s
    })
    sprintf(@subscribe_msg, name)
  end
  
  #
  # confirms new user subscription
  #
  def confirm_subscribe
    return @subscribe_err if self.is_subscribed # must not already be subscribed
    return @confirm_err if !self.is_subscribed(true) # must be in queue
    
    user = self.get_user(@phone, true)
    @db[@users_coll].insert({
      'name' => user['name'],
      'phone' => @phone,
      'ts' => Time.now.to_s
    })
    @db[@users_uc_coll].remove({'phone' => @phone})
    sprintf(@confirm_msg, user['name'])
  end
  
  #
  # unsubscribes the user
  #
  def unsubscribe
    return @unsubscribe_err if !self.is_subscribed # must be subscribed
    
    @db[@users_coll].remove({'phone' => @phone})
    @unsubscribe_msg
  end
  
  #
  # allows admin to subscribe a user
  #
  def admin_subscribe(name, phone)
    return @general_err if !self.is_admin # must be admin
    return @numfmt_err if phone.match(/^\d{10}$/) === nil # US phone numbers only
    phone = "+1#{phone}"
    return sprintf(@admin_subscribe_err, phone) if
      @db[@users_coll].find_one({'phone' => phone}) != nil # must not already be subscribed
    
    @db[@users_coll].insert({
      'name' => name,
      'phone' => phone,
      'ts' => Time.now.to_s
    })
    sprintf(@admin_subscribe_msg, name, phone)
  end
  
  #
  # allows admin to unsubscribe a user
  #
  def admin_unsubscribe(phone)
    return @general_err if !self.is_admin # must be admin
    return @numfmt_err if phone.match(/^\d{10}$/) === nil # US phone numbers only
    phone = "+1#{phone}"
    return sprintf(@admin_unsubscribe_err, phone) if
      @db[@users_coll].find_one({'phone' => phone}) == nil # must be subscribed
    
    @db[@users_coll].remove({'phone' => phone})
    sprintf(@admin_unsubscribe_msg, phone)
  end
  
  #
  # returns the number of subscribers
  #
	def count_subscribers()
		return @general_err if !self.is_admin # must be admin
		
		@db[@users_coll].count
	end
	
  #
  # queues up SMS broadcast
  #
  def broadcast(msg)
    return @general_err if !self.is_admin # must be admin
    
    @db[@broadcast_queue].remove({'admin_phone' => @phone})
    @db[@broadcast_queue].insert({
      'admin_phone' => @phone,
      'message' => msg,
      'ts' => Time.now.to_s
    })
    @broadcast_msg
  end
  
  #
  # confirms and sends SMS broadcast
  #
  def confirm_broadcast
    return @general_error if !self.is_admin # must be admin
    return @confirm_broadcast_notq_err if !self.has_broadcast_pending # must have message in queue
    
    # retrieve message from queue
    broadcast = @db[@broadcast_queue].find_one({'admin_phone' => @phone})
    
    # send it
    client = Twilio::REST::Client.new $account_sid, $auth_token
    users = @db[@users_coll].find
    users.each do |user|
      # puts "SEND! #{user['name']}, #{user['phone']}" #TESTING
      client.account.sms.messages.create(
        :from => $sw_alerts_number,
        :to => user['phone'],
        :body => broadcast['message']
      )
    end
    
    # archive message
    @db[@broadcast_archive].insert({
      'admin_phone' => @phone,
      'message' => broadcast['message'],
      'ts' => Time.now.to_s
    })
    
    # remove from queue
    @db[@broadcast_queue].remove({'admin_phone' => @phone})
    @confirm_broadcast_msg
  end
  
end