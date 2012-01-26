//
//  PlaylistsUITableViewCell.m
//  iSub
//
//  Created by Ben Baron on 4/2/10.
//  Copyright 2010 Ben Baron. All rights reserved.
//

#import "PlaylistsUITableViewCell.h"
#import "ViewObjectsSingleton.h"
#import "MusicSingleton.h"
#import "DatabaseSingleton.h"
#import "CellOverlay.h"
#import "NSString+md5.h"
#import "NSMutableURLRequest+SUS.h"
#import "SUSServerPlaylist.h"
#import "NSMutableURLRequest+SUS.h"
#import "CustomUIAlertView.h"
#import "Song.h"
#import "TBXML.h"

@implementation PlaylistsUITableViewCell

@synthesize receivedData;
@synthesize playlistNameScrollView, playlistNameLabel;
@synthesize serverPlaylist, isDownload;

#pragma mark - Lifecycle
 
- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier 
{
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) 
	{		
		isDownload = NO;
		
		playlistNameScrollView = [[UIScrollView alloc] init];
		playlistNameScrollView.frame = CGRectMake(5, 10, 310, 44);
		playlistNameScrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
		playlistNameScrollView.showsVerticalScrollIndicator = NO;
		playlistNameScrollView.showsHorizontalScrollIndicator = NO;
		playlistNameScrollView.userInteractionEnabled = NO;
		playlistNameScrollView.decelerationRate = UIScrollViewDecelerationRateFast;
		[self.contentView addSubview:playlistNameScrollView];
		[playlistNameScrollView release];
		
		playlistNameLabel = [[UILabel alloc] init];
		playlistNameLabel.backgroundColor = [UIColor clearColor];
		playlistNameLabel.textAlignment = UITextAlignmentLeft; // default
		playlistNameLabel.font = [UIFont boldSystemFontOfSize:20];
		[playlistNameScrollView addSubview:playlistNameLabel];
		[playlistNameLabel release];
    }
    return self;
}

- (void)layoutSubviews 
{
    [super layoutSubviews];
	
	self.deleteToggleImage.frame = CGRectMake(4.0, 18.5, 23.0, 23.0);
	
	// Automatically set the width based on the width of the text
	playlistNameLabel.frame = CGRectMake(0, 0, 290, 44);
	CGSize expectedLabelSize = [playlistNameLabel.text sizeWithFont:playlistNameLabel.font constrainedToSize:CGSizeMake(1000,44) lineBreakMode:playlistNameLabel.lineBreakMode]; 
	CGRect newFrame = playlistNameLabel.frame;
	newFrame.size.width = expectedLabelSize.width;
	playlistNameLabel.frame = newFrame;
}

#pragma mark - Overlay

- (void)downloadAction
{
	[[ViewObjectsSingleton sharedInstance] showLoadingScreenOnMainWindow];
	
    NSDictionary *parameters = [NSDictionary dictionaryWithObject:n2N(serverPlaylist.playlistId) forKey:@"id"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithSUSAction:@"getPlaylist" andParameters:parameters];
    
    NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:request delegate:self];
	if (connection)
	{
        isDownload = YES;
		self.receivedData = [NSMutableData dataWithCapacity:0];
	} 
	else 
	{
		// TODO: Handle error
	}
	
	self.overlayView.downloadButton.alpha = .3;
	self.overlayView.downloadButton.enabled = NO;
	
	[self hideOverlay];
}

- (void)queueAction
{
	[[ViewObjectsSingleton sharedInstance] showLoadingScreenOnMainWindow];
	
    NSDictionary *parameters = [NSDictionary dictionaryWithObject:n2N(serverPlaylist.playlistId) forKey:@"id"];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithSUSAction:@"getPlaylist" andParameters:parameters];
    
    NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:request delegate:self];
	if (connection)
	{
        isDownload = NO;
		self.receivedData = [NSMutableData dataWithCapacity:0];
	} 
	else 
	{
		// TODO: Handle error
	}
    
	[self hideOverlay];
}

#pragma mark - Scrolling

- (void)scrollLabels
{
	if (playlistNameLabel.frame.size.width > playlistNameScrollView.frame.size.width)
	{
		[UIView beginAnimations:@"scroll" context:nil];
		[UIView setAnimationDelegate:self];
		[UIView setAnimationDidStopSelector:@selector(textScrollingStopped)];
		[UIView setAnimationDuration:playlistNameLabel.frame.size.width/(float)150];
		playlistNameScrollView.contentOffset = CGPointMake(playlistNameLabel.frame.size.width - playlistNameScrollView.frame.size.width + 10, 0);
		[UIView commitAnimations];
	}
}

- (void)textScrollingStopped
{
	[UIView beginAnimations:@"scroll" context:nil];
	[UIView setAnimationDuration:playlistNameLabel.frame.size.width/(float)150];
	playlistNameScrollView.contentOffset = CGPointZero;
	[UIView commitAnimations];
}

#pragma mark - Connection Delegate

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
	[self.receivedData setLength:0];
}

- (void)connection:(NSURLConnection *)theConnection didReceiveData:(NSData *)incrementalData 
{
    [self.receivedData appendData:incrementalData];
}

- (void)connection:(NSURLConnection *)theConnection didFailWithError:(NSError *)error
{
	self.receivedData = nil;
	[theConnection release];
	
	// Inform the delegate that loading failed
	[[ViewObjectsSingleton sharedInstance] hideLoadingScreen];
}	

- (void)connectionDidFinishLoading:(NSURLConnection *)theConnection 
{	
    // Parse the data
    //
    TBXML *tbxml = [[TBXML alloc] initWithXMLData:self.receivedData];
    TBXMLElement *root = tbxml.rootXMLElement;
    if (root) 
    {
        TBXMLElement *error = [TBXML childElementNamed:@"error" parentElement:root];
        if (error)
        {
            // TODO: handle error
        }
        else
        {
            TBXMLElement *playlist = [TBXML childElementNamed:@"playlist" parentElement:root];
            if (playlist)
            {
                NSString *md5 = [serverPlaylist.playlistName md5];
                [[DatabaseSingleton sharedInstance] removeServerPlaylistTable:md5];
                [[DatabaseSingleton sharedInstance] createServerPlaylistTable:md5];
                
                TBXMLElement *entry = [TBXML childElementNamed:@"entry" parentElement:playlist];
                while (entry != nil)
                {
                    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
                    
                    Song *aSong = [[Song alloc] initWithTBXMLElement:entry];
                    [aSong insertIntoServerPlaylistWithPlaylistId:md5];
                    if (isDownload)
                    {
                        [aSong addToCacheQueue];
                    }
                    else
                    {
                        [aSong addToCurrentPlaylist];
                    }
                    [aSong release];
                    
                    // Get the next message
                    entry = [TBXML nextSiblingNamed:@"entry" searchFromElement:entry];
                    
                    [pool release];
                }
            }
        }
    }
	[tbxml release];
	
	// Hide the loading screen
	[[ViewObjectsSingleton sharedInstance] hideLoadingScreen];
	
	self.receivedData = nil;
	[theConnection release];
}

@end
