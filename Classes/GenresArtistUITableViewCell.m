//
//  ArtistUITableViewCell.m
//  iSub
//
//  Created by Ben Baron on 5/7/10.
//  Copyright 2010 Ben Baron. All rights reserved.
//

#import "GenresArtistUITableViewCell.h"
#import "ViewObjectsSingleton.h"
#import "MusicSingleton.h"
#import "DatabaseSingleton.h"
#import "FMDatabaseAdditions.h"
#import "CellOverlay.h"
#import "Song.h"


@implementation GenresArtistUITableViewCell

@synthesize genre, artistNameScrollView, artistNameLabel;

#pragma mark - Lifecycle

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier 
{
	if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) 
	{		
		artistNameScrollView = [[UIScrollView alloc] init];
		artistNameScrollView.showsVerticalScrollIndicator = NO;
		artistNameScrollView.showsHorizontalScrollIndicator = NO;
		artistNameScrollView.userInteractionEnabled = NO;
		artistNameScrollView.decelerationRate = UIScrollViewDecelerationRateFast;
		[self.contentView addSubview:artistNameScrollView];
		[artistNameScrollView release];
		
		artistNameLabel = [[UILabel alloc] init];
		artistNameLabel.backgroundColor = [UIColor clearColor];
		artistNameLabel.textAlignment = UITextAlignmentLeft; // default
		artistNameLabel.font = [UIFont boldSystemFontOfSize:20];
		[artistNameScrollView addSubview:artistNameLabel];
		[artistNameLabel release];
	}
	
	return self;
}

- (void)layoutSubviews 
{	
    [super layoutSubviews];
	
	self.contentView.frame = CGRectMake(0, 0, 320, 44);
	artistNameScrollView.frame = CGRectMake(5, 0, 250, 44);
	
	// Automatically set the width based on the width of the text
	artistNameLabel.frame = CGRectMake(0, 0, 250, 44);
	CGSize expectedLabelSize = [artistNameLabel.text sizeWithFont:artistNameLabel.font constrainedToSize:CGSizeMake(1000,44) lineBreakMode:artistNameLabel.lineBreakMode]; 
	CGRect newFrame = artistNameLabel.frame;
	newFrame.size.width = expectedLabelSize.width;
	artistNameLabel.frame = newFrame;
}

- (void)dealloc 
{
	[genre release]; genre = nil;
    [super dealloc];
}

#pragma mark - Overlay

- (void)showOverlay
{
	[super showOverlay];
	if (self.isOverlayShowing)
	{
		if ([ViewObjectsSingleton sharedInstance].isOfflineMode)
		{
			self.overlayView.downloadButton.enabled = NO;
			self.overlayView.downloadButton.hidden = YES;
		}
	}
}

- (void)downloadAllSongs
{
	FMResultSet *result;
	if ([ViewObjectsSingleton sharedInstance].isOfflineMode) 
	{
		result = [[DatabaseSingleton sharedInstance].songCacheDb executeQuery:@"SELECT md5 FROM cachedSongsLayout WHERE seg1 = ? AND genre = ? ORDER BY seg2 COLLATE NOCASE", artistNameLabel.text, genre];
	}
	else 
	{
		result = [[DatabaseSingleton sharedInstance].genresDb executeQuery:@"SELECT md5 FROM genresLayout WHERE seg1 = ? AND genre = ? ORDER BY seg2 COLLATE NOCASE", artistNameLabel.text, genre];
	}
	
	while ([result next])
	{
		if ([result stringForColumnIndex:0] != nil)
			[[Song songFromGenreDb:[NSString stringWithString:[result stringForColumnIndex:0]]] addToCacheQueue];
	}
	[result close];
	
	// Hide the loading screen
	[[ViewObjectsSingleton sharedInstance] hideLoadingScreen];
}

- (void)downloadAction
{
	[[ViewObjectsSingleton sharedInstance] showLoadingScreenOnMainWindowWithMessage:nil];
	[self performSelector:@selector(downloadAllSongs) withObject:nil afterDelay:0.05];
	
	self.overlayView.downloadButton.alpha = .3;
	self.overlayView.downloadButton.enabled = NO;
	
	[self hideOverlay];
}

- (void)queueAllSongs
{
	FMResultSet *result;
	if ([ViewObjectsSingleton sharedInstance].isOfflineMode) 
	{
		result = [[DatabaseSingleton sharedInstance].songCacheDb executeQuery:@"SELECT md5 FROM cachedSongsLayout WHERE seg1 = ? AND genre = ? ORDER BY seg2 COLLATE NOCASE", artistNameLabel.text, genre];
	}
	else 
	{
		result = [[DatabaseSingleton sharedInstance].genresDb executeQuery:@"SELECT md5 FROM genresLayout WHERE seg1 = ? AND genre = ? ORDER BY seg2 COLLATE NOCASE", artistNameLabel.text, genre];
	}
	
	while ([result next])
	{
		if ([result stringForColumnIndex:0] != nil)
			[[Song songFromGenreDb:[NSString stringWithString:[result stringForColumnIndex:0]]] addToCurrentPlaylist];
	}
	[result release];
	
	[[ViewObjectsSingleton sharedInstance] hideLoadingScreen];
}

- (void)queueAction
{
	[[ViewObjectsSingleton sharedInstance] showLoadingScreenOnMainWindowWithMessage:nil];
	[self performSelector:@selector(queueAllSongs) withObject:nil afterDelay:0.05];
	[self hideOverlay];
}

#pragma mark - Scrolling

- (void)scrollLabels
{
	if (artistNameLabel.frame.size.width > artistNameScrollView.frame.size.width)
	{
		[UIView beginAnimations:@"scroll" context:nil];
		[UIView setAnimationDelegate:self];
		[UIView setAnimationDidStopSelector:@selector(textScrollingStopped)];
		[UIView setAnimationDuration:artistNameLabel.frame.size.width/(float)150];
		artistNameScrollView.contentOffset = CGPointMake(artistNameLabel.frame.size.width - artistNameScrollView.frame.size.width + 10, 0);
		[UIView commitAnimations];
	}
}

- (void)textScrollingStopped
{
	[UIView beginAnimations:@"scroll" context:nil];
	[UIView setAnimationDuration:artistNameLabel.frame.size.width/(float)150];
	artistNameScrollView.contentOffset = CGPointZero;
	[UIView commitAnimations];
}

@end
