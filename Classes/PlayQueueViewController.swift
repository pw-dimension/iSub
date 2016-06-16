//
//  PlayQueueViewController.swift
//  iSub
//
//  Created by Benjamin Baron on 2/5/16.
//  Copyright © 2016 Ben Baron. All rights reserved.
//

import UIKit
import SnapKit
import JASidePanels
import libSub

class PlayQueueViewController: DraggableTableViewController {

    var hoverRow = -1
    
    private let viewModel: PlayQueueViewModel
    private let currentItemReuseIdentifier = "Current Item Cell"
    private let itemReuseIdentifier = "Item Cell"
    private var visible: Bool {
        return self.sidePanelController.state == JASidePanelRightVisible
    }
    
    init(viewModel: PlayQueueViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        
        self.viewModel.delegate = self
        
        NSNotificationCenter.addObserverOnMainThread(self, selector: #selector(PlayQueueViewController.draggingBegan(_:)), name: DraggableTableView.Notifications.draggingBegan, object: nil)
        NSNotificationCenter.addObserverOnMainThread(self, selector: #selector(PlayQueueViewController.draggingMoved(_:)), name: DraggableTableView.Notifications.draggingMoved, object: nil)
        NSNotificationCenter.addObserverOnMainThread(self, selector: #selector(PlayQueueViewController.draggingEnded(_:)), name: DraggableTableView.Notifications.draggingEnded, object: nil)
        NSNotificationCenter.addObserverOnMainThread(self, selector: #selector(PlayQueueViewController.draggingCanceled(_:)), name: DraggableTableView.Notifications.draggingCanceled, object: nil)
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("NSCoding not supported")
    }
    
    deinit {
        NSNotificationCenter.removeObserverOnMainThread(self, name: DraggableTableView.Notifications.draggingBegan, object: nil)
        NSNotificationCenter.removeObserverOnMainThread(self, name: DraggableTableView.Notifications.draggingMoved, object: nil)
        NSNotificationCenter.removeObserverOnMainThread(self, name: DraggableTableView.Notifications.draggingEnded, object: nil)
        NSNotificationCenter.removeObserverOnMainThread(self, name: DraggableTableView.Notifications.draggingCanceled, object: nil)
    }
    
    // MARK - Drag and Drop -
    
    @objc private func draggingBegan(notification: NSNotification) {
        
    }
    
    @objc private func draggingMoved(notification: NSNotification) {
        if let userInfo = notification.userInfo {
            if let dragCell = userInfo[DraggableTableView.Notifications.dragCellKey] as? DraggableCell where dragCell.dragItem is ISMSSong,
               let location = userInfo[DraggableTableView.Notifications.locationKey] as? NSValue {
                
                var point = location.CGPointValue()
                // Treat hovers over the top portion of the cell as the previous cell
                point.y -= (ISMSNormalize(ISMSSongCellHeight) / 2.0)
                let tablePoint = tableView.convertPoint(point, fromView: nil)
                
                let indexPath = tableView.indexPathForRowAtPoint(tablePoint)
                var row = -1
                if let indexPath = indexPath {
                    row = indexPath.row
                }
                
                if hoverRow != row {
                    hoverRow = row
                    
                    // Reload cell heights
                    tableView.beginUpdates()
                    tableView.endUpdates()
                }
            }
        }
    }
    
    @objc private func draggingEnded(notification: NSNotification) {
        var reloadTable = true
        
        if visible, let userInfo = notification.userInfo {
            if let dragCell = userInfo[DraggableTableView.Notifications.dragCellKey] as? DraggableCell,
                   song = dragCell.dragItem as? ISMSSong,
                   dragSourceTableView = userInfo[DraggableTableView.Notifications.dragSourceTableViewKey] as? UITableView,
                   location = userInfo[DraggableTableView.Notifications.locationKey] as? NSValue {
                
                let point = location.CGPointValue()
                let localPoint = self.view.convertPoint(point, fromView: nil)
                if self.view.bounds.contains(localPoint) {
                    if dragSourceTableView === self.tableView, let fromIndex = dragCell.indexPath?.row {
                        let toIndex = hoverRow + 1
                        if fromIndex != toIndex {
                            viewModel.moveSong(fromIndex: fromIndex, toIndex: toIndex)
                            reloadTable = false
                        }
                    } else {
                        viewModel.insertSongAtIndex(hoverRow + 1, song: song)
                        reloadTable = false
                    }
                }
            }
        }
        
        if reloadTable {
            self.tableView.reloadData()
        }
        hoverRow = -1
    }
    
    @objc private func draggingCanceled(notification: NSNotification) {
        self.tableView.reloadData()
        hoverRow = -1
    }
    
    override func customizeTableView(tableView: UITableView) {
        // Move under the status bar
        tableView.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 20))
        
        tableView.backgroundColor = UIColor.clearColor()
        tableView.separatorColor = UIColor.blackColor()
        tableView.registerClass(ItemTableViewCell.self, forCellReuseIdentifier: itemReuseIdentifier)
        tableView.registerClass(CurrentItemCell.self, forCellReuseIdentifier: currentItemReuseIdentifier)
    }
    
    override func numberOfSectionsInTableView(tableView: UITableView) -> Int {
        return 1
    }
    
    override func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return viewModel.numberOfRows
    }
    
    override func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        let row = indexPath.row
        if row == viewModel.currentIndex, let cell = tableView.dequeueReusableCellWithIdentifier(currentItemReuseIdentifier, forIndexPath: indexPath) as? CurrentItemCell {
            cell.cellHeight = 60.0
            cell.accessoryType = .None
            cell.indexPath = indexPath
            cell.associatedObject = viewModel.songAtIndex(indexPath.row)
            return cell
        } else if let cell = tableView.dequeueReusableCellWithIdentifier(itemReuseIdentifier, forIndexPath: indexPath) as? ItemTableViewCell {
            cell.alwaysShowSubtitle = true
            cell.cellHeight = ISMSNormalize(ISMSSongCellHeight)
            cell.accessoryType = .None
            
            let song = viewModel.songAtIndex(indexPath.row)
            cell.indexPath = indexPath
            cell.associatedObject = song
            cell.coverArtId = nil
            cell.trackNumber = song.trackNumber
            cell.title = song.title
            cell.subTitle = song.artist?.name
            cell.duration = song.duration
            // TODO: Readd this with new data model
            //cell.playing = song.isCurrentPlayingSong()
            
            if song.isFullyCached {
                cell.backgroundView = UIView()
                cell.backgroundView!.backgroundColor = ViewObjectsSingleton.sharedInstance().currentLightColor()
            } else {
                cell.backgroundView = UIView()
            }
            return cell
        }
        
        // Should never happen
        return UITableViewCell()
    }
    
    override func tableView(tableView: UITableView, heightForRowAtIndexPath indexPath: NSIndexPath) -> CGFloat {
        var height = indexPath.row == viewModel.currentIndex ? 60.0 : ISMSNormalize(ISMSSongCellHeight)
        if indexPath.row == hoverRow {
            height += ISMSNormalize(ISMSSongCellHeight)
        }
        return height
    }
    
    override func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        viewModel.playSongAtIndex(indexPath.row)
    }
}

extension PlayQueueViewController: PlayQueueViewModelDelegate {
    func itemsChanged() {
        self.tableView.reloadData()
        
        let indexPath = NSIndexPath(forRow: self.viewModel.currentIndex, inSection: 0)
        if visible {
            EX2Dispatch.runInMainThreadAfterDelay(0.5) {
                self.tableView.scrollToRowAtIndexPath(indexPath, atScrollPosition: .Top, animated: self.visible)
            }
        } else {
            self.tableView.scrollToRowAtIndexPath(indexPath, atScrollPosition: .Top, animated: self.visible)
        }
    }
}

@objc class CurrentItemCell: DroppableCell, DraggableCell {
    var indexPath: NSIndexPath?
    var associatedObject: AnyObject? {
        didSet {
            if let song = associatedObject as? ISMSSong {
                coverArtView.coverArtId = song.coverArtId
                songLabel.text = song.title
                artistLabel.text = song.artist?.name
            }
        }
    }
    
    let coverArtView = AsynchronousImageView()
    let songLabel = UILabel()
    let artistLabel = UILabel()
    
    private func commonInit() {
        super.backgroundColor = .lightGrayColor()
        
        containerView.addSubview(coverArtView)
        coverArtView.snp_makeConstraints { make in
            make.top.equalTo(containerView)
            make.leading.equalTo(containerView)
            make.bottom.equalTo(containerView)
            make.width.equalTo(60)
        }
        
        songLabel.font = UIFont.systemFontOfSize(14)
        songLabel.textColor = UIColor.blackColor()
        songLabel.textAlignment = .Center
        containerView.addSubview(songLabel)
        songLabel.snp_makeConstraints { make in
            make.top.equalTo(containerView)
            make.leading.equalTo(coverArtView.snp_trailing).offset(5)
            make.trailing.equalTo(containerView).inset(5)
            make.height.equalTo(40)
        }
        
        artistLabel.font = UIFont.systemFontOfSize(10)
        artistLabel.textColor = UIColor.grayColor()
        artistLabel.textAlignment = .Center
        containerView.addSubview(artistLabel)
        artistLabel.snp_makeConstraints { make in
            make.top.equalTo(songLabel.snp_bottom)
            make.leading.equalTo(songLabel)
            make.trailing.equalTo(songLabel)
            make.height.equalTo(20)
        }
    }
    
    override init(style: UITableViewCellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        commonInit()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }
    
    var draggable: Bool {
        return true
    }
    
    var dragItem: ISMSItem? {
        return associatedObject as? ISMSItem
    }
}
