local Blitbuffer = require("ffi/blitbuffer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local FocusManager = require("ui/widget/focusmanager")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local OverlapGroup = require("ui/widget/overlapgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RenderImage = require("ui/renderimage")
local LineWidget = require("ui/widget/linewidget")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local ImageWidget = require("ui/widget/imagewidget")
local TitleBar = require("ui/widget/titlebar")
local TextWidget = require("ui/widget/textwidget")
local DocumentRegistry = require("document/documentregistry")
local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local logger = require("logger")

local ButtonTable = require("ui/widget/buttontable")
local DocSettings = require("docsettings")
local util = require("util")
local Device = require("device")
local Backend = require("Legado/Backend")
local H = require("Legado/Helper")
local Env = require("Legado.Helper.Env")

local Screen = Device.screen

local Constants = {
    COVER_WIDTH_RATIO_PORTRAIT = 0.4,
    COVER_WIDTH_RATIO_LANDSCAPE = 0.3,
    COVER_MAX_HEIGHT_RATIO = 1/3,
    METADATA_TOP_PADDING_RATIO = 0.15,
    METADATA_HORIZONTAL_SPACING_RATIO = 0.02,
    DETAILS_HORIZONTAL_PADDING_RATIO = 0.05,
    DESCRIPTION_HEIGHT_RATIO = 5 / 15,
    BUTTON_GROUP_SHRINK_MIN_WIDTH_RATIO = 0.5,
    COVER_IMAGE_MARGIN = 5,
    COVER_IMAGE_PADDING = 10,
    COVER_IMAGE_BORDER_SIZE = 1,
    PLACEHOLDER_COVER = "resources/koreader.png",
}

local BookDetails = FocusManager:extend{
    padding = Size.padding.fullscreen,
    bookinfo = nil,
    callbacks = nil,
    has_reload_btn = nil,
    lnk_file = nil,
    is_downloading = nil,
}

function BookDetails:init()
    if not H.is_tbl(self.bookinfo) then return end

    -- The book id may not be generated yet
    if not self.bookinfo.cache_id then
        self.bookinfo.name = util.trim(self.bookinfo.name)
        self.bookinfo.author = util.trim(self.bookinfo.author or "")
        if self.bookinfo.author == "" then
            self.bookinfo.author = '未知'
        end
        local show_book_title = ("%s (%s)"):format(self.bookinfo.name, self.bookinfo.author)
        self.bookinfo.cache_id = tostring(H.md5(show_book_title))
    end

    self.layout = {}
    self.small_font = Font:getFace("smallffont")
    self.medium_font = Font:getFace("ffont")
    self.large_font = Font:getFace("largeffont")
    -- "portrait" - 竖屏模式 "landscape" - 横屏模式
    self.screen_mode = Screen:getScreenMode()
    self.screen_size = Screen:getSize()

    self.covers_fullscreen = true
    self[1] = FrameContainer:new{
        dimen = Geom:new{
            w = self.screen_size.w,
            h = self.screen_size.h,
        },
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        self:getDetailsContent(self.screen_size.w)
    }

    if Device:hasKeys() then
        if Device.Input and Device.Input.group and Device.Input.group.Back then
            self.key_events.Close = { { Device.Input.group.Back } }
        end
        if Device:hasFewKeys() then
            self.key_events.Close = { { "Left" } }
        end
    end
end

function BookDetails:getDetailsContent(width)
    local title_bar = TitleBar:new{
        width = width,
        bottom_v_padding = 0,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local book_details = self:getBookDetails()
    local header = self:getHeader("简介")
    local description = self:getDescriptionContent()

    -- Calculate the height of all elements except the button group
    local other_elements_height = title_bar:getSize().h +
                                  book_details:getSize().h +
                                  header:getSize().h +
                                  description:getSize().h

    local button_group = self:getButtonGroup(other_elements_height)

    local content = VerticalGroup:new{
        align = "left",
        title_bar,
        book_details,
        header,
        description,
        button_group,
    }
    return content
end

function BookDetails:getButtonGroup(other_elements_height)
    local buttons = {}
    if H.is_tbl(self.buttons) and H.is_tbl(self.buttons[1]) then
        for _, btn in ipairs(self.buttons) do
            table.insert(buttons, {
                text = btn.text,
                callback = function()
                    if H.is_func(btn.callback) then
                        btn.callback(self.bookinfo)
                    end
                    self:onClose()
                end
            })
        end
    end
    if self.has_reload_btn then
        table.insert(buttons, {
            text = "刷新封面",
            callback = function()
                if self.is_downloading then return end
                local image_path = Backend:get_default_cover_cache(self.bookinfo.cache_id)  
                if H.is_str(image_path) and util.fileExists(image_path) then
                    pcall(util.removeFile, image_path)
                end
                if self.lnk_file then
                    local custom_book_cover = DocSettings:findCustomCoverFile(self.lnk_file)
                    if H.is_str(custom_book_cover) and util.fileExists(custom_book_cover) then
                        pcall(util.removeFile, custom_book_cover)
                    end
                end
                UIManager:nextTick(function()
                    if not util.fileExists(image_path) then 
                        self:_reload() 
                        if self.lnk_file then Backend:emitMetadataChanged(self.lnk_file) end
                    end
                end)  
            end,
        })
    end
    if H.is_str(self.lnk_file) and util.fileExists(self.lnk_file) then
        table.insert(buttons, {
            text = "自定义封面",
            callback = function()
                local path_chooser = require("ui/widget/pathchooser"):new{
                    title ="长按图片选择",
                    select_directory = false,
                    path = Env.getHomeDir(),
                    onConfirm = function(image_file)
                        if not H.is_str(image_file) then return end
                        if DocumentRegistry:isImageFile(image_file) then
                            if DocSettings:flushCustomCover(self.lnk_file, image_file) then
                                self:_reload()
                                Backend:emitMetadataChanged(self.lnk_file)
                            end
                        else
                            logger.warn("更换封面: 仅支持图片文件")
                        end
                    end,
                }
                UIManager:show(path_chooser)
            end,
        })
    end
    table.insert(buttons, {
        text = "返回",
        callback = function()
            self:onClose()
        end,
    })

    -- Create vertical button layout first to check height
    local vertical_buttons = {}
    for _, btn in ipairs(buttons) do
        table.insert(vertical_buttons, {btn})
    end

    local button_table = ButtonTable:new {
        buttons = vertical_buttons,
        show_parent = self,
        shrink_unneeded_width = true,
        shrink_min_width = self.screen_size.w * Constants.BUTTON_GROUP_SHRINK_MIN_WIDTH_RATIO,
    }

    -- Calculate remaining height
    local remaining_height = self.screen_size.h - other_elements_height

    -- If too tall, switch to horizontal layout
    if button_table:getSize().h > remaining_height then
        button_table = ButtonTable:new {
            width = self.screen_size.w,
            buttons = {buttons}, -- Single row for horizontal layout
            show_parent = self,
        }
    end
    
    return CenterContainer:new{
        dimen = Geom:new{ w = self.screen_size.w, h = remaining_height },
        FrameContainer:new{
            bordersize = Constants.COVER_IMAGE_BORDER_SIZE,
            margin = 0,
            padding = 0,
            button_table,
        }
    }
end

function BookDetails:_createCoverImage(cover_bb, max_width, max_height, min_frame_height)
    min_frame_height = min_frame_height or 0
    local actual_w, actual_h
    if not cover_bb then
        -- Do not delete placeholder image
        -- pcall(util.removeFile, image_path)
        cover_bb = self:getCoverimage()
        if not cover_bb then
            actual_w, actual_h = max_width, max_height
        end
    else
        actual_w, actual_h = cover_bb:getWidth(), cover_bb:getHeight()
    end

    local container_w = max_width - (Constants.COVER_IMAGE_PADDING * 2)
    local container_h = max_height - (Constants.COVER_IMAGE_PADDING * 2)
    local scale_w = container_w / actual_w
    local scale_h = container_h / actual_h
    local scale = math.min(scale_w, scale_h)

    local scaled_w = math.floor(actual_w * scale)
    local scaled_h = math.floor(actual_h * scale)

    local image_widget = ImageWidget:new{
        image = cover_bb,
        width = scaled_w,
        height = scaled_h,
        scale_factor = 0,
        alpha = true,
    }

    -- The final container height must be at least min_frame_height.
    -- The container's height is determined by its child (CenterContainer) + padding, margin, and border.
    -- So, we need to calculate the required height for the CenterContainer.
    local non_content_h = (Constants.COVER_IMAGE_PADDING * 2) + (Constants.COVER_IMAGE_MARGIN * 2) + (Constants.COVER_IMAGE_BORDER_SIZE * 2)
    local min_center_container_h = min_frame_height - non_content_h
    local center_container_h = math.max(scaled_h, min_center_container_h)

    return FrameContainer:new{
        bordersize = Constants.COVER_IMAGE_BORDER_SIZE,
        margin = Constants.COVER_IMAGE_MARGIN,
        padding = Constants.COVER_IMAGE_PADDING,
        CenterContainer:new{
            dimen = Geom:new{
                w = container_w, -- Use full available width to center the image
                h = center_container_h,
            },
            image_widget
        }
    }, image_widget
end

function BookDetails:_createMetadataGroup(metadata_table)
    local metadata_label_group = VerticalGroup:new{
        align = "left",
    }
    local metadata_labeled_group = VerticalGroup:new{
        align = "left",
    }

    for _, item in ipairs(metadata_table) do
        table.insert(metadata_label_group, TextWidget:new{
            text = item.label,
            face = self.small_font,
            fgcolor = Blitbuffer.COLOR_GRAY_9,
        })
        table.insert(metadata_labeled_group, TextWidget:new{
            text = item.value or "N/A",
            face = self.small_font,
        })
    end

    return HorizontalGroup:new{
        align = "top",
        metadata_label_group,
        HorizontalSpan:new{ width = math.floor(self.screen_size.w * Constants.METADATA_HORIZONTAL_SPACING_RATIO)},
        metadata_labeled_group,
    }
end

function BookDetails:getBookDetails()
    local screen_width = self.screen_size.w
    local screen_height = self.screen_size.h

    local img_width_ratio = self.screen_mode == "landscape" and Constants.COVER_WIDTH_RATIO_LANDSCAPE or Constants.COVER_WIDTH_RATIO_PORTRAIT
    local img_width = screen_width * img_width_ratio
    local img_max_height = screen_height * Constants.COVER_MAX_HEIGHT_RATIO

    -- Create metadata group
    local book_author_string = self.bookinfo.author or "Unknown Author"
    local book_metadata_group = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = img_max_height * Constants.METADATA_TOP_PADDING_RATIO},
        TextWidget:new{
            text = self.bookinfo.name or "Unknown Title",
            face = self.large_font,
        },
        TextWidget:new{
            text = "by " .. book_author_string,
            face = self.medium_font,
        }
    }
    local metadata_table = {
        { label = "分类", value = self.bookinfo.kind },
        { label = "来源", value = self.bookinfo.originName },
        { label = "总章数", value = self.bookinfo.totalChapterNum },
        { label = "总字数", value = self.bookinfo.wordCount },
    }
    table.insert(book_metadata_group, self:_createMetadataGroup(metadata_table))

    -- Ensure cover image is at least as tall as the metadata
    local metadata_height = book_metadata_group:getSize().h
    img_max_height = math.max(img_max_height, metadata_height)

    local final_cover_component
    local cover_bitmap = self:getCoverimage(self.lnk_file, self.bookinfo.cache_id)
    
    if not ( cover_bitmap and H.is_func(cover_bitmap.getWidth) ) then
        
        local book_cache_id = self.bookinfo.cache_id
        local cover_url = self.bookinfo.coverUrl

        -- Create placeholder image container
        cover_bitmap = self:getCoverimage()
        local placeholder_container, _ = self:_createCoverImage(cover_bitmap, img_width, img_max_height, metadata_height)

        self.loading_text_widget = TextWidget:new{
            text = "正在加载",
            face = self.medium_font,
            fgcolor = Blitbuffer.COLOR_GRAY_9
        }

        -- Combine placeholder and text widget
        local cover_group = OverlapGroup:new{
                    placeholder_container,
                    CenterContainer:new{
                        dimen = Geom:new{
                            w = placeholder_container:getSize().w,
                            h = placeholder_container:getSize().h,
                        },
                        self.loading_text_widget,
                    }
            }
        
        final_cover_component = cover_group
        
        -- 没有文件才进行下载
        if not Backend:get_default_cover_cache(book_cache_id) then
            self.is_downloading = true
            Backend:launchProcess(function()
                return Backend:download_cover_img(book_cache_id, cover_url)
            end, function(status, cover_path, cover_name)
                if self.loading_text_widget then
                    if status == true and H.is_str(cover_path) and util.fileExists(cover_path) then
                    self:reloadCoverImage()
                    else
                        self.loading_text_widget:setText("下载失败")
                        UIManager:setDirty("all", "partial")
                        UIManager:forceRePaint()
                    end
                end
                self.is_downloading = nil
            end)
        else
            self.loading_text_widget:setText("资源损坏")
            UIManager:setDirty("all", "partial")
            UIManager:forceRePaint()
        end 
    else
        local cover_image_container, cover_image_widget = self:_createCoverImage(cover_bitmap, img_width, img_max_height, metadata_height)
        self.cover_image_widget = cover_image_widget
        final_cover_component = cover_image_container
    end

    local book_details_group = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = math.floor(screen_width * Constants.DETAILS_HORIZONTAL_PADDING_RATIO) }
    }
    if final_cover_component then
        table.insert(book_details_group, final_cover_component)
    end
    table.insert(book_details_group, HorizontalSpan:new{ width = math.floor(screen_width * Constants.DETAILS_HORIZONTAL_PADDING_RATIO) })
    table.insert(book_details_group, book_metadata_group)

    return book_details_group
end

function BookDetails:getHeader(title)
    local width, height = self.screen_size.w, Size.item.height_default

    local header_title = TextWidget:new{
        text = title,
        face = self.medium_font,
        fgcolor = Blitbuffer.COLOR_GRAY_9
    }
    local padding_span = HorizontalSpan:new{ width = self.padding }
    local line_width = (width - header_title:getSize().w) / 2 - self.padding * 2
    line_width = math.max(0, line_width) -- ensure line_width is not negative
    local line_container = LeftContainer:new{
        dimen = Geom:new{ w = line_width, h = height },
        LineWidget:new{
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            dimen = Geom:new{
                w = line_width,
                h = Size.line.thick,
            }
        }
    }

    local span_top, span_bottom
    if self.screen_mode == "landscape" then
        span_top = VerticalSpan:new{ width = Size.span.horizontal_default }
        span_bottom = VerticalSpan:new{ width = Size.span.horizontal_default }
    else
        span_top = VerticalSpan:new{ width = Size.item.height_default }
        span_bottom = VerticalSpan:new{ width = Size.span.vertical_large }
    end

    return VerticalGroup:new{
        span_top,
        HorizontalGroup:new{
            align = "center",
            padding_span,
            line_container,
            padding_span,
            header_title,
            padding_span,
            line_container,
            padding_span,
        },
        span_bottom,
    }
end

function BookDetails:getDescriptionContent()
    local screen_width = self.screen_size.w
    local screen_height = self.screen_size.h
    
    local text = ScrollTextWidget:new{
        text = self:decodeHtmlEntities(self.bookinfo.intro or ""),
        --face = self.medium_font,
        face = Font:getFace("infont"),
        width = screen_width - self.padding * 2,
        height = screen_height * Constants.DESCRIPTION_HEIGHT_RATIO,
        dialog = self,
    }

    return CenterContainer:new{
        dimen = Geom:new{ w = screen_width, h = text:getSize().h },
        text
    }
end

function BookDetails:reloadCoverImage()
    local image_path = Backend:get_default_cover_cache(self.bookinfo.cache_id)
    if H.is_str(image_path) and util.fileExists(image_path) then
        self:_reload()
        if self.lnk_file then Backend:emitMetadataChanged(self.lnk_file) end
    end
end

function BookDetails:decodeHtmlEntities(text)
    return util.htmlEntitiesToUtf8(text)
end

function BookDetails:getCoverimage(path, book_cache_id)
    if not (path or book_cache_id ) then
        -- get_cover_bitmap(Constants.PLACEHOLDER_COVER)
        return RenderImage:renderImageFile(Constants.PLACEHOLDER_COVER, false)
    end

    -- if the picture is damaged, it will crash.
    local ok, cover_bb =  pcall(FileManagerBookInfo.getCoverImage, FileManagerBookInfo, nil, path)
    if ok and cover_bb and H.is_func(cover_bb.getWidth) then
        local w, h = cover_bb:getWidth(), cover_bb:getHeight()
        if w > 0 and h > 0 then
            return cover_bb
        end
    else
        if book_cache_id then
            local cover_path = Backend:get_default_cover_cache(book_cache_id)
            if H.is_str(cover_path) and util.fileExists(cover_path) then
                -- supports gz compression
                local get_cover_bitmap = function(cover_file)
                    local cover_doc = DocumentRegistry:openDocument(cover_file)
                    if cover_doc then
                        ok, cover_bb = pcall(cover_doc.getCoverPageImage, cover_doc)
                        cover_doc:close()
                        if ok and cover_bb and H.is_func(cover_bb.getWidth) then return cover_bb end 
                    end
                end
                return get_cover_bitmap(cover_path)
            end
        end
    end
    return nil
end
    

function BookDetails:_reload()
    self[1][1] = self:getDetailsContent(self.screen_size.w)
    UIManager:setDirty("all", "partial")
    UIManager:forceRePaint()
end

function BookDetails:onShow()
    UIManager:setDirty(self, function()
        return "ui", self[1].dimen
    end)
end

function BookDetails:onCloseWidget()
    if self.cover_image_widget and self.cover_image_widget.free then
        self.cover_image_widget:free()
    end
    UIManager:setDirty(nil, function()
        return "ui", self[1].dimen
    end)
end

function BookDetails:onClose()
    UIManager:close(self)
    return true
end

return BookDetails
