//
//  SocialControlsSingleton.m
//  iSub
//
//  Created by Ben Baron on 10/15/10.
//  Copyright 2010 Ben Baron. All rights reserved.
//

#import "SocialSingleton.h"
#import "SA_OAuthTwitterEngine.h"
#import "SA_OAuthTwitterController.h"
#import "CustomUIAlertView.h"

#import "SavedSettings.h"
#import "SUSCurrentPlaylistDAO.h"
#import "Song.h"
#import "NSMutableURLRequest+SUS.h"

// Twitter secret keys
#define kOAuthConsumerKey				@"nYKAEcLstFYnI9EEnv6g"
#define kOAuthConsumerSecret			@"wXSWVvY7GN1e8Z2KFaR9A5skZKtHzpchvMS7Elpu0"

static SocialSingleton *sharedInstance = nil;

@implementation SocialSingleton

@synthesize tweetTimer, shouldInvalidateTweetTimer, scrobbleTimer, shouldInvalidateScrobbleTimer;

// Twitter
@synthesize twitterEngine;


#pragma mark -
#pragma mark Class instance methods

- (void)songStarted
{
	if (shouldInvalidateTweetTimer)
	{
		[tweetTimer invalidate];
        [tweetTimer release];
        tweetTimer = nil;
	}
	
	if (shouldInvalidateScrobbleTimer)
	{
		[scrobbleTimer invalidate];
        [scrobbleTimer release];
        scrobbleTimer = nil;
	}
	
	// Start song tweeting timer for 30 seconds
	shouldInvalidateTweetTimer = YES;
	self.tweetTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self selector:@selector(tweetSong) userInfo:nil repeats:NO];

	// Scrobbling timer
	SavedSettings *settings = [SavedSettings sharedInstance];
	SUSCurrentPlaylistDAO *dataModel = [SUSCurrentPlaylistDAO dataModel];
	Song *currentSong = dataModel.currentSong;
	shouldInvalidateScrobbleTimer = YES;
	NSTimeInterval scrobbleInterval = 30.0;
	if (currentSong.duration != nil)
	{
		float scrobblePercent = settings.scrobblePercent;
		float duration = [currentSong.duration floatValue];
		scrobbleInterval = scrobblePercent * duration;
		DLog(@"duration: %f    percent: %f    scrobbleInterval: %f", duration, scrobblePercent, scrobbleInterval);
	}
	self.scrobbleTimer = [NSTimer scheduledTimerWithTimeInterval:scrobbleInterval target:self selector:@selector(scrobbleSong) userInfo:nil repeats:NO];
	
	// If scrobbling is enabled, send "now playing" call
	if (settings.isScrobbleEnabled)
	{
		[self scrobbleSong:currentSong isSubmission:NO];
	}
}

#pragma mark - Scrobbling -

- (void)scrobbleSong
{
	shouldInvalidateScrobbleTimer = NO;
	scrobbleTimer = nil;
	
	if ([SavedSettings sharedInstance].isScrobbleEnabled)
	{
		SUSCurrentPlaylistDAO *dataModel = [SUSCurrentPlaylistDAO dataModel];
		Song *currentSong = dataModel.currentSong;
		[self scrobbleSong:currentSong isSubmission:YES];
	}
}

- (void)scrobbleSong:(Song*)aSong isSubmission:(BOOL)isSubmission
{
    NSString *isSubmissionString = [NSString stringWithFormat:@"%i", isSubmission];
    NSDictionary *parameters = [NSDictionary dictionaryWithObjectsAndKeys:n2N(aSong.songId), @"id", n2N(isSubmissionString), @"submission", nil];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithSUSAction:@"scrobble" andParameters:parameters];
    
	[[NSURLConnection alloc] initWithRequest:request delegate:self];
}

#pragma mark Subsonic chache notification hack and Last.fm scrobbling connection delegate

- (BOOL)connection:(NSURLConnection *)connection canAuthenticateAgainstProtectionSpace:(NSURLProtectionSpace *)space 
{
	if([[space authenticationMethod] isEqualToString:NSURLAuthenticationMethodServerTrust]) 
		return YES; // Self-signed cert will be accepted
	
	return NO;
}

- (void)connection:(NSURLConnection *)connection didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
{	
	if([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust])
	{
		[challenge.sender useCredential:[NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust] forAuthenticationChallenge:challenge]; 
	}
	[challenge.sender continueWithoutCredentialForAuthenticationChallenge:challenge];
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response
{
	// Do nothing
}

- (void)connection:(NSURLConnection *)theConnection didReceiveData:(NSData *)incrementalData 
{
	if ([incrementalData length] > 0)
	{
		// Subsonic has been notified, cancel the connection
		[theConnection cancel];
		[theConnection release];
	}
}

- (void)connection:(NSURLConnection *)theConnection didFailWithError:(NSError *)error
{
	DLog(@"Subsonic cached song play notification failed\n\nError: %@", [error localizedDescription]);
	[theConnection release];
}	

- (void)connectionDidFinishLoading:(NSURLConnection *)theConnection 
{	
	[theConnection release];
}

#pragma mark - Twitter -

- (void)tweetSong
{
	SavedSettings *settings = [SavedSettings sharedInstance];
	SUSCurrentPlaylistDAO *dataModel = [SUSCurrentPlaylistDAO dataModel];
	Song *currentSong = dataModel.currentSong;
	
	shouldInvalidateTweetTimer = NO;
	tweetTimer = nil;
	
	if (twitterEngine && settings.isTwitterEnabled)
	{
		if (currentSong.artist && currentSong.title)
		{
			DLog(@"------------- tweeting song --------------");
			NSString *tweet = [NSString stringWithFormat:@"is listening to \"%@\" by %@", currentSong.title, currentSong.artist];
			if ([tweet length] <= 140)
				[twitterEngine sendUpdate:tweet];
			else
				[twitterEngine sendUpdate:[tweet substringToIndex:140]];
		}
		else 
		{
			DLog(@"------------- not tweeting song because either no artist or no title --------------");
		}
		
	}
	else 
	{
		DLog(@"------------- not tweeting song because no engine or not enabled --------------");
	}
}

- (void) createTwitterEngine
{
	if (twitterEngine)
		return;
	
	self.twitterEngine = [[SA_OAuthTwitterEngine alloc] initOAuthWithDelegate: self];
	self.twitterEngine.consumerKey = kOAuthConsumerKey;
	self.twitterEngine.consumerSecret = kOAuthConsumerSecret;
	
	// Needed to load saved twitter auth info
	[self.twitterEngine isAuthorized];
}

//=============================================================================================================================
// SA_OAuthTwitterEngineDelegate
- (void) storeCachedTwitterOAuthData:(NSString *)data forUsername:(NSString *)username 
{
	DLog(@"storeCachedTwitterOAuthData: %@ for %@", data, username);
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	
	[defaults setObject:data forKey:@"twitterAuthData"];
	[defaults synchronize];
}

- (NSString *) cachedTwitterOAuthDataForUsername:(NSString *)username 
{
	DLog(@"cachedTwitterOAuthDataForUsername for %@", username);
	return [[NSUserDefaults standardUserDefaults] objectForKey:@"twitterAuthData"];
}

//=============================================================================================================================
// SA_OAuthTwitterControllerDelegate
- (void) OAuthTwitterController:(SA_OAuthTwitterController *)controller authenticatedWithUsername:(NSString *)username 
{
	DLog(@"Authenicated for %@", username);
	[[NSNotificationCenter defaultCenter] postNotificationName:@"twitterAuthenticated" object:nil];
}

- (void) OAuthTwitterControllerFailed:(SA_OAuthTwitterController *)controller 
{
	DLog(@"Authentication Failed!");
	self.twitterEngine = nil;
	UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Twitter Error" message:@"Failed to authenticate user. Try logging in again." delegate:self cancelButtonTitle:@"Ok" otherButtonTitles:nil];
	[alert performSelectorOnMainThread:@selector(show) withObject:nil waitUntilDone:NO];
	[alert release];
}

- (void) OAuthTwitterControllerCanceled:(SA_OAuthTwitterController *)controller 
{
	DLog(@"Authentication Canceled.");
	self.twitterEngine = nil;
}

//=============================================================================================================================
// TwitterEngineDelegate
- (void) requestSucceeded:(NSString *)requestIdentifier 
{
	DLog(@"Request %@ succeeded", requestIdentifier);
}

- (void) requestFailed:(NSString *)requestIdentifier withError:(NSError *) error 
{
	DLog(@"Request %@ failed with error: %@", requestIdentifier, error);
}

#pragma mark -
#pragma mark Singleton methods

+ (SocialSingleton*)sharedInstance
{
    @synchronized(self)
    {
        if (sharedInstance == nil)
			[[self alloc] init];
    }
    return sharedInstance;
}

- (void)setup
{
	//initialize here
	twitterEngine = nil;
	[self createTwitterEngine];
	
	tweetTimer = nil;
	shouldInvalidateTweetTimer = NO;
	scrobbleTimer = nil;
	shouldInvalidateScrobbleTimer = NO;
	
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(songStarted) name:ISMSNotification_SongPlaybackStarted object:nil];
}

+ (id)allocWithZone:(NSZone *)zone {
    @synchronized(self) {
        if (sharedInstance == nil) {
            sharedInstance = [super allocWithZone:zone];
			[sharedInstance setup];
            return sharedInstance;  // assignment and return on first allocation
        }
    }
    return nil; // on subsequent allocation attempts return nil
}

-(id)init 
{
	self = [super init];
	sharedInstance = self;
	
	[self setup];
	
	return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    return self;
}

- (id)retain {
    return self;
}

- (unsigned)retainCount {
    return UINT_MAX;  // denotes an object that cannot be released
}

- (oneway void)release {
    //do nothing
}

- (id)autorelease {
    return self;
}

@end