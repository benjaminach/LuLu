//
//  FilterDataProvider.m
//  LuLu
//
//  Created by Patrick Wardle on 8/1/20.
//  Copyright (c) 2020 Objective-See. All rights reserved.
//

#import "Rule.h"
#import "Rules.h"
#import "Alerts.h"
#import "consts.h"
#import "GrayList.h"
#import "BlockOrAllowList.h"
#import "utilities.h"
#import "Preferences.h"
#import "XPCUserProto.h"
#import "FilterDataProvider.h"

/* GLOBALS */

//alerts
extern Alerts* alerts;

//log handle
extern os_log_t logHandle;

//rules
extern Rules* rules;

//preferences
extern Preferences* preferences;

//allow list
extern BlockOrAllowList* allowList;

//block list
extern BlockOrAllowList* blockList;

//allow list
extern

@implementation FilterDataProvider

@synthesize cache;
@synthesize grayList;

//init
-(id)init
{
    //super
    self = [super init];
    if(nil != self)
    {
        //init cache
        cache = [[NSCache alloc] init];
        
        //set cache limit
        self.cache.countLimit = 2048;
        
        //init gray list
        grayList = [[GrayList alloc] init];
        
        //alloc related flows
        self.relatedFlows = [NSMutableDictionary dictionary];
        
    }
    
    return self;
}

//start filter
-(void)startFilterWithCompletionHandler:(void (^)(NSError *error))completionHandler {

    //rule
    NENetworkRule* networkRule = nil;
    
    //filter rule
    NEFilterRule* filterRule = nil;
    
    //filter settings
    NEFilterSettings* filterSettings = nil;
    
    //log msg
    os_log_debug(logHandle, "%s", __PRETTY_FUNCTION__);
    
    //init network rule
    // any/all outbound traffic
    networkRule = [[NENetworkRule alloc] initWithRemoteNetwork:nil remotePrefix:0 localNetwork:nil localPrefix:0 protocol:NENetworkRuleProtocolAny direction:NETrafficDirectionOutbound];
    
    //init filter rule
    // filter traffic, based on network rule
    filterRule = [[NEFilterRule alloc] initWithNetworkRule:networkRule action:NEFilterActionFilterData];
    
    //init filter settings
    filterSettings = [[NEFilterSettings alloc] initWithRules:@[filterRule] defaultAction:NEFilterActionAllow];
    
    //apply rules
    [self applySettings:filterSettings completionHandler:^(NSError * _Nullable error) {
        
        //log msg
        os_log_debug(logHandle, "'applySettings' completed");
        
        //error?
        if(nil != error) os_log_error(logHandle, "ERROR: failed to apply filter settings: %@", error.localizedDescription);
        
        //call completion handler
        completionHandler(error);
        
    }];
    
    return;
    
}

//stop filter
-(void)stopFilterWithReason:(NEProviderStopReason)reason completionHandler:(void (^)(void))completionHandler {
    
    //log msg
    os_log_debug(logHandle, "method '%s' invoked with %ld", __PRETTY_FUNCTION__, (long)reason);
    
    //extra dbg info
    if(NEProviderStopReasonUserInitiated == reason)
    {
        //log msg
        os_log_debug(logHandle, "reason: NEProviderStopReasonUserInitiated");
    }
    
    //required
    completionHandler();
    
    return;
}

//handle flow
// a) skip local/inbound traffic
// b) lookup matching rule & then apply
// c) ...or ask user (alert via XPC) if no rule
-(NEFilterNewFlowVerdict *)handleNewFlow:(NEFilterFlow *)flow {
    
    //socket flow
    NEFilterSocketFlow* socketFlow = nil;
    
    //remote endpoint
    NWHostEndpoint* remoteEndpoint = nil;
    
    //verdict
    NEFilterNewFlowVerdict* verdict = nil;
    
    //log msg
    os_log_debug(logHandle, "method '%s' invoked", __PRETTY_FUNCTION__);
    
    //init verdict to allow
    verdict = [NEFilterNewFlowVerdict allowVerdict];
    
    //no prefs (yet) or disabled
    // just allow the flow (don't block)
    if( (0 == preferences.preferences.count) ||
        (YES == [preferences.preferences[PREF_IS_DISABLED] boolValue]) )
    {
        //dbg msg
        os_log_debug(logHandle, "no prefs (yet) || disabled, so allowing flow");
        
        //bail
        goto bail;
    }
    
    //typecast
    socketFlow = (NEFilterSocketFlow*)flow;
    
    //log msg
    //os_log_debug(logHandle, "flow: %{public}@", flow);
    
    //extract remote endpoint
    remoteEndpoint = (NWHostEndpoint*)socketFlow.remoteEndpoint;
    
    //log msg
    os_log_debug(logHandle, "remote endpoint: %{public}@ / url: %{public}@", remoteEndpoint, flow.URL);
    
    //ignore non-outbound traffic
    // even though we init'd `NETrafficDirectionOutbound`, sometimes get inbound traffic :|
    if(NETrafficDirectionOutbound != socketFlow.direction)
    {
        //log msg
        os_log_debug(logHandle, "ignoring non-outbound traffic (direction: %ld)", (long)socketFlow.direction);
           
        //bail
        goto bail;
    }
    
    //process flow
    // determine verdict
    // deliver alert (if necessary)
    verdict = [self processEvent:flow];
    
    //log msg
    os_log_debug(logHandle, "verdict: %{public}@", verdict);
    
bail:
        
    return verdict;
}

//process a network out event from the network extension (OS)
// if there is no matching rule, will tell client to show alert
-(NEFilterNewFlowVerdict*)processEvent:(NEFilterFlow*)flow
{
    //verdict
    // allow/deny
    NEFilterNewFlowVerdict* verdict = nil;
    
    //pool
    //@autoreleasepool
    //{
    
    //process obj
    Process* process = nil;
    
    //flag
    BOOL csChange = NO;
    
    //matching rule obj
    Rule* matchingRule = nil;
    
    //console user
    NSString* consoleUser = nil;
    
    //rule info
    NSMutableDictionary* info = nil;
    
    //default to allow (on errors, etc)
    verdict = [NEFilterNewFlowVerdict allowVerdict];
    
    //(ext) install date
    static NSDate* installDate = nil;
    
    //token
    static dispatch_once_t onceToken = 0;
    
    //grab console user
    consoleUser = getConsoleUser();
    
    //check cache for process
    process = [self.cache objectForKey:flow.sourceAppAuditToken];
    if(nil == process)
    {
        //dbg msg
        os_log_debug(logHandle, "no process found in cache, will create");
        
        //create
        // also adds to cache
        process = [self createProcess:flow];
    }

    //dbg msg
    else os_log_debug(logHandle, "found process object in cache: %{public}@ (pid: %d)", process.path, process.pid);
    
    //sanity check
    // no process? just allow...
    if(nil == process)
    {
        //err msg
        os_log_error(logHandle, "ERROR: failed to create process for flow, will allow");
        
        //bail
        goto bail;
    }
        
    //(now), broadcast notification
    // allows anybody to listen to flows
    [[NSDistributedNotificationCenter defaultCenter] postNotificationName:LULU_EVENT object:@"new flow" userInfo:[alerts create:(NEFilterSocketFlow*)flow process:process] options:NSNotificationDeliverImmediately|NSNotificationPostToAllSessions];
            
    //dbg msg
    //os_log_debug(logHandle, "process object for flow: %{public}@", process);
    
    //CHECK:
    // different logged in user?
    // just allow flow, as we don't want to block their traffic
    if( (nil != consoleUser) &&
        (YES != [alerts.consoleUser isEqualToString:consoleUser]) )
    {
        //dbg msg
        os_log_debug(logHandle, "current console user '%{public}@', is different than '%{public}@', so allowing flow: %{public}@", consoleUser, alerts.consoleUser, ((NEFilterSocketFlow*)flow).remoteEndpoint);
        
        //all set
        goto bail;
    }
    
    //CHECK:
    // client in (full) block mode? ...block!
    // unless there is an allow list set, which we'll check
    if(YES == [preferences.preferences[PREF_BLOCK_MODE] boolValue])
    {
        //but allow list set?
        if( (YES == [preferences.preferences[PREF_USE_ALLOW_LIST] boolValue]) &&
            (YES == [allowList isMatch:(NEFilterSocketFlow*)flow]) )
        {
            //dbg msg
            os_log_debug(logHandle, "client in block mode, but flow matches item in allow list, so allowing");
                
            //allow
            verdict = [NEFilterNewFlowVerdict allowVerdict];
                
            //all set
            goto bail;
        }
        
        //dbg msg
        os_log_debug(logHandle, "client in block mode (and item not on allow list), so disallowing %d/%{public}@", process.pid, process.binary.name);
        
        //deny
        verdict = [NEFilterNewFlowVerdict dropVerdict];
        
        //all set
        goto bail;
    }
        
    //CHECK:
    // client using (global) block list
    if( (YES == [preferences.preferences[PREF_USE_BLOCK_LIST] boolValue]) &&
        (0 != [preferences.preferences[PREF_BLOCK_LIST] length]) )
    {
        //dbg msg
        os_log_debug(logHandle, "client is using block list '%{public}@' (%lu items) ...will check for match", preferences.preferences[PREF_BLOCK_LIST], (unsigned long)blockList.items.count);
        
        //match in block list?
        if(YES == [blockList isMatch:(NEFilterSocketFlow*)flow])
        {
            //dbg msg
            os_log_debug(logHandle, "flow matches item in block list, so denying");
            
            //deny
            verdict = [NEFilterNewFlowVerdict dropVerdict];
            
            //all set
            goto bail;
        }
        //dbg msg
        else os_log_debug(logHandle, "remote endpoint/URL not on block list...");
    }
    
    //CHECK:
    // client using (global) allow list
    if( (YES == [preferences.preferences[PREF_USE_ALLOW_LIST] boolValue]) &&
        (0 != [preferences.preferences[PREF_ALLOW_LIST] length]) )
    {
        //dbg msg
        os_log_debug(logHandle, "client is using allow list '%{public}@' (%lu items) ...will check for match", preferences.preferences[PREF_ALLOW_LIST], (unsigned long)allowList.items.count);
        
        //match in allow list?
        if(YES == [allowList isMatch:(NEFilterSocketFlow*)flow])
        {
            //dbg msg
            os_log_debug(logHandle, "flow matches item in allow list, so allowing");
            
            //allow
            verdict = [NEFilterNewFlowVerdict allowVerdict];
            
            //all set
            goto bail;
        }
        
        //dbg msg
        else os_log_debug(logHandle, "remote endpoint/URL not on allow list...");
    }
        
    //CHECK:
    // check for existing rule
    
    //existing rule for process?
    matchingRule = [rules find:process flow:(NEFilterSocketFlow*)flow csChange:&csChange];
    if(nil != matchingRule)
    {
        //dbg msg
        os_log_debug(logHandle, "found matching rule for %d/%{public}@: %{public}@", process.pid, process.binary.name, matchingRule);
        
        //matching rule !global/!directory?
        // add its 'external' path (as might be different than original)
        if( (YES != matchingRule.isGlobal.boolValue) &&
            (YES != matchingRule.isDirectory.boolValue) )
        {
            //add path
            if(nil != process.path)
            {
                //add
                [rules.rules[process.key][KEY_PATHS] addObject:process.path];
            }
        }
        
        //deny?
        // otherwise will default to allow
        if(RULE_STATE_BLOCK == matchingRule.action.intValue)
        {
            //dbg msg
            os_log_debug(logHandle, "setting verdict to: BLOCK");
            
            //deny
            verdict = [NEFilterNewFlowVerdict dropVerdict];
        }
        //allow (msg)
        else os_log_debug(logHandle, "rule says: ALLOW");
    
        //all set
        goto bail;
    }

    /* NO MATCHING RULE FOUND */
    
    //cs change?
    // update item's rules with new code signing info
    // note: user will be informed about this, if/when alert is delivered
    if(YES == csChange)
    {
        //dbg msg
        os_log_debug(logHandle, "found rule set for %d/%{public}@: %{public}@, but code signing info has changed", process.pid, process.binary.name, matchingRule);
        
        //update cs info
        [rules updateCSInfo:process];
    }
    //no matching rule found?
    else
    {
        //dbg msg
        os_log_debug(logHandle, "no (saved) rule found for %d/%{public}@", process.pid, process.binary.name);
    }

    //CHECK:
    // client in passive mode?
    // take action based on user's settting ...allow/block
    if(YES == [preferences.preferences[PREF_PASSIVE_MODE] boolValue])
    {
        //dbg msg
        os_log_debug(logHandle, "client in passive mode...");
        
        //user action: allow?
        if(PREF_PASSIVE_MODE_ALLOW == [preferences.preferences[PREF_PASSIVE_MODE_ACTION] integerValue])
        {
            //dbg msg
            os_log_debug(logHandle, "passive mode: action is 'allow', so allowing %d/%{public}@", process.pid, process.binary.name);
            
            //allow
            verdict = [NEFilterNewFlowVerdict allowVerdict];
        }
        
        //user action: block?
        else
        {
            //dbg msg
            os_log_debug(logHandle, "passive mode: action is 'block', so blocking %d/%{public}@", process.pid, process.binary.name);
            
            //block
            verdict = [NEFilterNewFlowVerdict dropVerdict];
        }
        
        //create rule?
        if(PREF_PASSIVE_MODE_RULES_YES == [preferences.preferences[PREF_PASSIVE_MODE_RULES] integerValue])
        {
            //dbg msg
            os_log_debug(logHandle, "passive mode: create rules is set, so creating rule for new connection");
            
            //extract remote endpoint information
            NWHostEndpoint* remoteEndpoint = (NWHostEndpoint*)((NEFilterSocketFlow*)flow).remoteEndpoint;
            
            //init info for rule creation with specific endpoint information
            info = [@{KEY_PATH:process.path} mutableCopy];
            
            //add endpoint address (hostname) if available
            if(nil != remoteEndpoint.hostname && ![remoteEndpoint.hostname isEqualToString:@""])
            {
                info[KEY_ENDPOINT_ADDR] = remoteEndpoint.hostname;
            }
            else
            {
                info[KEY_ENDPOINT_ADDR] = VALUE_ANY;
            }
            
            //add endpoint port if available
            if(nil != remoteEndpoint.port && ![remoteEndpoint.port isEqualToString:@""])
            {
                info[KEY_ENDPOINT_PORT] = remoteEndpoint.port;
            }
            else
            {
                info[KEY_ENDPOINT_PORT] = VALUE_ANY;
            }
            
            //add protocol if available
            if(((NEFilterSocketFlow*)flow).socketProtocol > 0)
            {
                info[KEY_PROTOCOL] = [NSNumber numberWithInt:((NEFilterSocketFlow*)flow).socketProtocol];
            }

            //add process cs info?
            if(nil != process.csInfo) info[KEY_CS_INFO] = process.csInfo;
            
            //add action: allow
            if(PREF_PASSIVE_MODE_ALLOW == [preferences.preferences[PREF_PASSIVE_MODE_ACTION] integerValue])
            {
                //dbg msg
                os_log_debug(logHandle, "passive mode: creating rule with 'allow'");
                
                //allow
                info[KEY_ACTION] = @RULE_STATE_ALLOW;
            }
            //add action: block
            else
            {
                //dbg msg
                os_log_debug(logHandle, "passive mode: creating rule with 'block'");
                
                //block
                info[KEY_ACTION] = @RULE_STATE_BLOCK;
            }
            
            //create and add rule
            if(YES != [rules add:[[Rule alloc] init:info] save:YES])
            {
                //err msg
                os_log_error(logHandle, "ERROR: failed to add (passive) rule for %{public}@", info[KEY_PATH]);
                 
                //bail
                goto bail;
            }
            
            //tell user rules changed
            [alerts.xpcUserClient rulesChanged];
        }
        //no rule creation needed
        else
        {
            //dbg msg
            os_log_debug(logHandle, "passive mode: create rules is not set...");
        }
        
        //all set
        goto bail;
    }
    
    //dbg msg
    os_log_debug(logHandle, "client not in passive mode...");
    
    //CHECK:
    // there is related alert shown (i.e. for same process)
    // save this flow, as only want to process once user responds to first alert
    if(YES == [alerts isRelated:process])
    {
        //dbg msg
        os_log_debug(logHandle, "an alert is shown for process %d/%{public}@, so holding off delivering for now...", process.pid, process.binary.name);
        
        //add related flow
        [self addRelatedFlow:process.key flow:(NEFilterSocketFlow*)flow];
        
        //pause
        verdict = [NEFilterNewFlowVerdict pauseVerdict];
        
        //bail
        goto bail;
    }
    
    //dbg msg
    os_log_debug(logHandle, "no related alert, currently shown...");
    
    //CHECK:
    // Apple process and 'PREF_ALLOW_APPLE' is set? Allow
    // Unless:
    //  a) Its on the 'graylist' (e.g. curl) as these can be (ab)used by malware
    //  b) There are other rules for this same process (even though they didn't match)
    if(YES == [preferences.preferences[PREF_ALLOW_APPLE] boolValue])
    {
        //dbg msg
        os_log_debug(logHandle, "'Allow Apple' preference is set, will check if is an Apple binary");
        
        //signed by Apple?
        if(Apple == [process.csInfo[KEY_CS_SIGNER] intValue])
        {
            //dbg msg
            os_log_debug(logHandle, "is an Apple binary...");
            
            //graylisted item?
            // pause and alert user
            if(YES == [self.grayList isGrayListed:process])
            {
                //dbg msg
                os_log_debug(logHandle, "while signed by apple, %d/%{public}@ is gray listed, so will alert", process.pid, process.binary.name);
                
                //pause
                verdict = [NEFilterNewFlowVerdict pauseVerdict];
                
                //create/deliver alert
                [self alert:(NEFilterSocketFlow*)flow process:process csChange:csChange];
            }
            //other rules for this process?
            else if(0 != [rules.rules[process.key][KEY_RULES] count])
            {
                //dbg msg
                os_log_debug(logHandle, "while signed by apple, %d/%{public}@ has other (non-matching) rules, so will alert", process.pid, process.binary.name);
                
                //pause
                verdict = [NEFilterNewFlowVerdict pauseVerdict];
                
                //create/deliver alert
                [self alert:(NEFilterSocketFlow*)flow process:process csChange:csChange];
            }
            //otherwise its a apple binary
            // not on graylist and w/ no other rules, so allow
            else
            {
                //dbg msg
                os_log_debug(logHandle, "due to preferences, allowing (non-graylisted) apple process %d/%{public}@", process.pid, process.path);
                
                //init for (rule) info
                // type: apple, action: allow
                info = [@{KEY_PATH:process.path, KEY_ACTION:@RULE_STATE_ALLOW, KEY_TYPE:@RULE_TYPE_APPLE} mutableCopy];
                
                //add process cs info
                if(nil != process.csInfo)
                {
                    //add
                    info[KEY_CS_INFO] = process.csInfo;
                }
                
                //add key
                info[KEY_KEY] = process.key;
                
                //add/save
                if(YES != [rules add:[[Rule alloc] init:info] save:YES])
                {
                    //err msg
                    os_log_error(logHandle, "ERROR: failed to add rule");
                    
                    //bail
                    goto bail;
                }
                
                //tell user rules changed
                [alerts.xpcUserClient rulesChanged];
            }
            
            //all set
            goto bail;
            
        } //signed by apple
    }
    //dbg msg
    else
    {
        //dbg msg
        os_log_debug(logHandle, "'Allow Apple' preference not set, so skipped 'Is Apple' check");
    }
    
    //'allow installed' check
    // if preference is enabled, item is 3rd-party, internal, and hasn't had its CS changed ...allow!
    if( (YES == [preferences.preferences[PREF_ALLOW_INSTALLED] boolValue]) &&
        (Apple != [process.csInfo[KEY_CS_SIGNER] intValue]) &&
        (YES != csChange) )
    {
        //only check internal processes
        // so, like ignore ones from DMGs, external drives, etc.
        if(YES == isInternalProcess(process.path))
        {
            //app date
            NSDate* date = nil;
            
            //dbg msg
            os_log_debug(logHandle, "3rd-party (internal) app, plus 'PREF_ALLOW_INSTALLED' is set...");
            
            //only once
            // get install date
            dispatch_once(&onceToken, ^{
                
                //get LuLu's install date
                installDate = preferences.preferences[PREF_INSTALL_TIMESTAMP];
                
                //dbg msg
                os_log_debug(logHandle, "LuLu's install date: %{public}@", installDate);
                
            });
            
            //get item's date added
            date = dateAdded(process.path);
            if( (nil != date) &&
                (NSOrderedAscending == [date compare:installDate]) )
            {
                //dbg msg
                os_log_debug(logHandle, "3rd-party item was installed prior (%@) to LuLu (%@), allowing & adding rule", date, installDate);
                
                //init info for rule creation
                info = [@{KEY_PATH:process.path, KEY_ACTION:@RULE_STATE_ALLOW, KEY_TYPE:@RULE_TYPE_BASELINE} mutableCopy];
                
                //add process cs info
                if(nil != process.csInfo)
                {
                    info[KEY_CS_INFO] = process.csInfo;
                }
                
                //create and add rule
                if(YES != [rules add:[[Rule alloc] init:info] save:YES])
                {
                    //err msg
                    os_log_error(logHandle, "ERROR: failed to add rule for %{public}@", info[KEY_PATH]);
                     
                    //bail
                    goto bail;
                }
                
                //tell user rules changed
                [alerts.xpcUserClient rulesChanged];
                
                //all set
                goto bail;
            }
            //newer
            else
            {
                //dbg msg
                os_log_debug(logHandle, "3rd-party item date (%@), is after LuLu's install date (%@)", date, installDate);
            }
        }
        //item is external
        else
        {
            os_log_debug(logHandle, "%{public}@ is external, so skipping 'allow installed' check", process.path);
        }
    }
    
    //allow dns traffic pref set?
    // really, just any UDP traffic over port 53
    if(YES == [preferences.preferences[PREF_ALLOW_DNS] boolValue])
    {
        //dbg msg
        os_log_debug(logHandle, "'allow DNS traffic' is enabled, so checking port/protocol");
        
        //check proto (UDP) and port (53)
        if( (IPPROTO_UDP == ((NEFilterSocketFlow*)flow).socketProtocol) &&
            (YES == [((NWHostEndpoint*)((NEFilterSocketFlow*)flow).remoteEndpoint).port isEqualToString:@"53"]) )
        {
            //dbg msg
            os_log_debug(logHandle, "protocol is 'UDP' and port is '53', (so likely DNS traffic) ...will allow" );
            
            //allow
            verdict = [NEFilterNewFlowVerdict allowVerdict];
            
            //done
            goto bail;
        }
    }
    
    //allow simulator apps?
    if(YES == [preferences.preferences[PREF_ALLOW_SIMULATOR] boolValue])
    {
        //dbg msg
        os_log_debug(logHandle, "'allow simulator apps' is enabled, so checking process");
        
        //is simulator app?
        if(YES == isSimulatorApp(process.path))
        {
            //dbg msg
            os_log_debug(logHandle, "%{public}@, is an simulator app, so will allow", process.path);
            
            //allow
            verdict = [NEFilterNewFlowVerdict allowVerdict];
            
            //done
            goto bail;
        }
    }
    
    //no user?
    // allow, but create rule for user to review
    if( (nil == consoleUser) ||
        (nil == alerts.xpcUserClient) )
    {
        //dbg msg
        os_log_debug(logHandle, "no active user or no connect client, will allow (and create rule)...");
        
        //init info for rule creation
        info = [@{KEY_PATH:process.path, KEY_ACTION:@RULE_STATE_ALLOW, KEY_TYPE:@RULE_TYPE_ALL} mutableCopy];

        //add process cs info?
        if(nil != process.csInfo) info[KEY_CS_INFO] = process.csInfo;
        
        //create and add rule
        if(YES != [rules add:[[Rule alloc] init:info] save:YES])
        {
            //err msg
            os_log_error(logHandle, "ERROR: failed to add rule for %{public}@", info[KEY_PATH]);
             
            //bail
            goto bail;
        }
        
        //tell user rules changed
        [alerts.xpcUserClient rulesChanged];
        
        //all set
        goto bail;
    }
    
    //sending to user, so pause!
    verdict = [NEFilterNewFlowVerdict pauseVerdict];
        
    //create/deliver alert
    // note: handles response + next/any related flow
    [self alert:(NEFilterSocketFlow*)flow process:process csChange:csChange];
    
bail:
    
    
    //;} //pool
    
    return verdict;
}

//1. Create and deliver alert
//2. Handle response (and process other shown alerts, etc.)
-(void)alert:(NEFilterSocketFlow*)flow process:(Process*)process csChange:(BOOL)csChange
{
    //alert
    NSMutableDictionary* alert = nil;
    
    //rule
    __block Rule* rule = nil;
    
    //create alert
    alert = [alerts create:(NEFilterSocketFlow*)flow process:process];
    
    //add cs change
    alert[KEY_CS_CHANGE] = [NSNumber numberWithBool:csChange];
    
    //dbg msg
    os_log_debug(logHandle, "created alert...");

    //deliver alert
    // and process user response
    if(YES != [alerts deliver:alert reply:^(NSDictionary* alert)
    {
        //verdict
        NEFilterNewFlowVerdict* verdict = nil;
        
        //log msg
        // note, this msg persists in log
        os_log(logHandle, "(user) response: \"%@\" for %{public}@, that was trying to connect to %{public}@:%{public}@", (RULE_STATE_BLOCK == [alert[KEY_ACTION] unsignedIntValue]) ? @"block" : @"allow", alert[KEY_PATH], alert[KEY_ENDPOINT_ADDR], alert[KEY_ENDPOINT_PORT]);
        
        //init verdict to allow
        verdict = [NEFilterNewFlowVerdict allowVerdict];
        
        //user replied with block?
        if( (nil != alert[KEY_ACTION]) &&
            (RULE_STATE_BLOCK == [alert[KEY_ACTION] unsignedIntValue]) )
        {
            //verdict: block
            verdict = [NEFilterNewFlowVerdict dropVerdict];
        }
        
        //resume flow w/ verdict
        [self resumeFlow:flow withVerdict:verdict];
        
        //init rule
        rule = [[Rule alloc] init:alert];

        //add / save
        [rules add:rule save:![rule isTemporary]];

        //remove from 'shown'
        [alerts removeShown:alert];
        
        //tell user rules changed
        [alerts.xpcUserClient rulesChanged];
        
        //process (any) related flows
        [self processRelatedFlow:alert[KEY_KEY]];
    }])
    {
        //failed to deliver
        // just allow flow...
        [self resumeFlow:flow withVerdict:[NEFilterNewFlowVerdict allowVerdict]];
    }
    
    //delivered to user
    else
    {
        //save as shown
        // needed so related (same process!) alerts aren't delivered as well
        [alerts addShown:alert];
    }
    
    return;
}


//add an alert to 'related'
// invoked when there is already an alert shown for process
// once user responds to alert, these will then be processed
-(void)addRelatedFlow:(NSString*)key flow:(NEFilterSocketFlow*)flow
{
    //dbg msg
    os_log_debug(logHandle, "adding flow to 'related': %{public}@ / %{public}@", key, flow);
    
    //sync/save
    @synchronized(self.relatedFlows)
    {
        //first time
        // init array for item (process) alerts
        if(nil == self.relatedFlows[key])
        {
            //create array
            self.relatedFlows[key] = [NSMutableArray array];
        }
        
        //add
        [self.relatedFlows[key] addObject:flow];
    }
    
    return;
}

//process related flows
-(void)processRelatedFlow:(NSString*)key
{
    //flows
    NSMutableArray* flows = nil;
    
    //flow
    NEFilterSocketFlow* flow = nil;
    
    //dbg msg
    os_log_debug(logHandle, "processing %lu related flow(s) for %{public}@", (unsigned long)[self.relatedFlows[key] count], key);
    
    //sync
    @synchronized(self.relatedFlows)
    {
        //grab flows for process
        flows = self.relatedFlows[key];
        for(NSInteger i = flows.count - 1; i >= 0; i--)
        {
            //grab flow
            flow = flows[i];
            
            //remove
            [flows removeObjectAtIndex:i];
           
            //process
            // pause means alert is/was shown
            // ...so stop, and wait for user response (which will retrigger processing)
            if([NEFilterNewFlowVerdict pauseVerdict] == [self processEvent:flow])
            {
                //stop
                break;
            }
        }
    }
   
bail:

    return;
}

//create process object
-(Process*)createProcess:(NEFilterFlow*)flow
{
    //audit token
    audit_token_t* token = NULL;
    
    //process obj
    Process* process = nil;
    
    //extract (audit) token
    token = (audit_token_t*)flow.sourceAppAuditToken.bytes;
    
    //init process object, via audit token
    process = [[Process alloc] init:token];
    if(nil == process)
    {
        //err msg
        os_log_error(logHandle, "ERROR: failed to create process for %d", audit_token_to_pid(*token));
        
        //bail
        goto bail;
    }
    
    //sync to add to cache
    @synchronized(self.cache) {
        
        //add to cache
        [self.cache setObject:process forKey:flow.sourceAppAuditToken];
    }
    
bail:
    
    return process;
}

@end
